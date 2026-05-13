#!/usr/bin/env python
import argparse
import ctypes
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

import pyautogui
import pygetwindow as gw
import pyperclip
from PIL import Image, ImageGrab
from rapidocr_onnxruntime import RapidOCR


pyautogui.FAILSAFE = False
pyautogui.PAUSE = 0.1
ocr_engine = RapidOCR()


def _normalize_window_title_text(text: str) -> str:
    cleaned = str(text).replace('\u200b', '').replace('\ufeff', '')
    cleaned = re.sub(r'\s+', ' ', cleaned).strip()
    return cleaned.casefold()


def _append_debug_log(entry: dict[str, Any], repo_path: str) -> None:
    log_dir = Path(repo_path) / 'plugins' / 'personal' / 'wechat-copilot-bridge' / 'logs'
    log_dir.mkdir(parents=True, exist_ok=True)
    log_path = log_dir / 'gh-computer-use-turns.jsonl'
    with log_path.open('a', encoding='utf-8') as handle:
        handle.write(json.dumps(entry, ensure_ascii=False) + '\n')


def _screen_size() -> tuple[int, int]:
    width, height = pyautogui.size()
    return int(width), int(height)


def _capture_screenshot_file() -> Path:
    temp_dir = Path(tempfile.gettempdir()) / 'wechat-copilot-bridge'
    temp_dir.mkdir(parents=True, exist_ok=True)
    screenshot_path = temp_dir / 'current-screen.png'

    last_error: Exception | None = None
    for attempt in range(3):
        try:
            screenshot = pyautogui.screenshot()
            screenshot.save(screenshot_path)
            return screenshot_path
        except OSError as error:
            last_error = error

        try:
            screenshot = ImageGrab.grab()
            screenshot.save(screenshot_path)
            return screenshot_path
        except OSError as error:
            last_error = error

        if attempt < 2:
            time.sleep(0.2)

    raise RuntimeError(f'Unable to capture the desktop screenshot after 3 attempts: {last_error}') from last_error


def _safe_window_title(window: Any) -> str:
    title = getattr(window, 'title', '') or ''
    return str(title).strip()


def _window_bounds(window: Any) -> dict[str, int]:
    left = int(getattr(window, 'left', 0) or 0)
    top = int(getattr(window, 'top', 0) or 0)
    width = int(getattr(window, 'width', 0) or 0)
    height = int(getattr(window, 'height', 0) or 0)
    return {
        'left': left,
        'top': top,
        'width': width,
        'height': height,
    }


def _get_window_snapshot() -> dict[str, Any]:
    try:
        active_window = gw.getActiveWindow()
    except Exception:
        active_window = None

    active_title = _safe_window_title(active_window)
    active_bounds = _window_bounds(active_window) if active_window is not None else {}
    visible_titles: list[str] = []

    try:
        for title in gw.getAllTitles():
            normalized = str(title).strip()
            if normalized:
                visible_titles.append(normalized)
    except Exception:
        visible_titles = []

    deduped_titles: list[str] = []
    seen_titles: set[str] = set()
    for title in visible_titles:
        lowered = title.lower()
        if lowered in seen_titles:
            continue
        seen_titles.add(lowered)
        deduped_titles.append(title)

    return {
        'activeTitle': active_title,
        'activeBounds': active_bounds,
        'visibleTitles': deduped_titles[:30],
    }


def _find_window_by_title(title: str) -> Any | None:
    expected = _normalize_window_title_text(title)
    if not expected:
        return None

    try:
        candidates = gw.getWindowsWithTitle(title)
    except Exception:
        candidates = []

    for window in candidates:
        if _safe_window_title(window):
            return window

    try:
        for current_title in gw.getAllTitles():
            normalized = str(current_title).strip()
            if normalized and expected in _normalize_window_title_text(normalized):
                matches = gw.getWindowsWithTitle(normalized)
                for window in matches:
                    if _safe_window_title(window):
                        return window
    except Exception:
        return None

    return None


def _activate_window_by_title(title: str) -> bool:
    window = _find_window_by_title(title)
    if window is None:
        return False

    try:
        if getattr(window, 'isMinimized', False):
            window.restore()
    except Exception:
        pass

    expected = _normalize_window_title_text(title)
    for _ in range(3):
        try:
            window.activate()
        except Exception:
            continue

        time.sleep(0.2)
        active_title = _normalize_window_title_text(_get_window_snapshot().get('activeTitle', ''))
        if expected and expected in active_title:
            return True

    return False


def _maximize_window_by_title(title: str) -> bool:
    window = _find_window_by_title(title)
    if window is None:
        return False

    try:
        if getattr(window, 'isMinimized', False):
            window.restore()
    except Exception:
        pass

    try:
        window.maximize()
        return True
    except Exception:
        return False


def _wait_for_window(title: str, timeout_seconds: float = 10.0) -> bool:
    expected = _normalize_window_title_text(title)
    deadline = time.time() + max(timeout_seconds, 0.1)
    while time.time() < deadline:
        window = _find_window_by_title(title)
        if window is not None:
            active_title = _normalize_window_title_text(_get_window_snapshot().get('activeTitle', ''))
            if expected and expected in active_title:
                return True
        time.sleep(0.25)
    return False


def _box_center(points: list[list[float]]) -> tuple[int, int]:
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    return int(sum(xs) / len(xs)), int(sum(ys) / len(ys))


def _ocr_screen(screenshot_path: Path) -> list[dict[str, Any]]:
    result, _ = ocr_engine(str(screenshot_path))
    items: list[dict[str, Any]] = []
    for entry in result or []:
        points, text, score = entry
        center_x, center_y = _box_center(points)
        items.append(
            {
                'text': str(text),
                'score': round(float(score), 4),
                'centerX': center_x,
                'centerY': center_y,
            }
        )
    return items


def _map_button(button: str | None) -> str:
    normalized = (button or 'left').lower()
    if normalized == 'wheel':
        return 'middle'
    if normalized in {'left', 'middle', 'right'}:
        return normalized
    return 'left'


def _map_key(key: str) -> str:
    normalized = key.strip().lower()
    aliases = {
        'control': 'ctrl',
        'ctrl': 'ctrl',
        'option': 'alt',
        'alternate': 'alt',
        'command': 'win',
        'cmd': 'win',
        'meta': 'win',
        'super': 'win',
        'windows': 'win',
        'return': 'enter',
        'escape': 'esc',
        'spacebar': 'space',
        'pageup': 'pgup',
        'pagedown': 'pgdn',
    }
    return aliases.get(normalized, normalized)


def _type_text_with_tokens(text: str) -> None:
    parts = re.split(r'(\{[^{}]+\})', text)
    for part in parts:
        if not part:
            continue

        if part.startswith('{') and part.endswith('}'):
            mapped_key = _map_key(part[1:-1])
            if mapped_key:
                pyautogui.press(mapped_key)
            continue

        original_clipboard: str | None = None
        clipboard_loaded = False
        try:
            original_clipboard = pyperclip.paste()
            clipboard_loaded = True
        except Exception:
            clipboard_loaded = False

        try:
            pyperclip.copy(part)
            time.sleep(0.05)
            pyautogui.hotkey('ctrl', 'v')
            time.sleep(0.05)
        except Exception:
            pyautogui.write(part, interval=0.01)
        finally:
            if clipboard_loaded:
                try:
                    pyperclip.copy(original_clipboard or '')
                except Exception:
                    pass


def _strip_control_tokens(text: str) -> str:
    return re.sub(r'\[\[(?:MEDIA_PATH|MEDIA_TEXT):.*?\]\]', '', text, flags=re.IGNORECASE | re.DOTALL).strip()


def _extract_media_path(user_prompt: str) -> str:
    match = re.search(r'\[\[MEDIA_PATH:(.*?)\]\]', user_prompt, re.IGNORECASE | re.DOTALL)
    if not match:
        return ''
    return str(match.group(1)).strip()


def _extract_media_text(user_prompt: str) -> str:
    match = re.search(r'\[\[MEDIA_TEXT:(.*?)\]\]', user_prompt, re.IGNORECASE | re.DOTALL)
    if not match:
        return ''
    return str(match.group(1)).strip()


def _image_to_dib_bytes(image_path: str) -> bytes:
    with Image.open(image_path) as opened_image:
        if opened_image.mode in {'RGBA', 'LA'}:
            background = Image.new('RGB', opened_image.size, (255, 255, 255))
            alpha = opened_image.getchannel('A') if 'A' in opened_image.getbands() else None
            background.paste(opened_image, mask=alpha)
            image = background
        else:
            image = opened_image.convert('RGB')

        buffer = io.BytesIO()
        image.save(buffer, format='BMP')
        bmp_bytes = buffer.getvalue()

    if len(bmp_bytes) <= 14:
        raise RuntimeError(f'Unable to convert image to BMP clipboard data: {image_path}')

    return bmp_bytes[14:]


def _copy_image_file_to_clipboard(image_path: str) -> None:
    if not image_path:
        raise ValueError('Image path is required for clipboard image paste.')

    resolved_path = Path(image_path).expanduser().resolve()
    if not resolved_path.exists():
        raise FileNotFoundError(f'Image file does not exist: {resolved_path}')

    dib_bytes = _image_to_dib_bytes(str(resolved_path))
    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    cf_dib = 8
    gmem_moveable = 0x0002

    user32.OpenClipboard.argtypes = [ctypes.c_void_p]
    user32.OpenClipboard.restype = ctypes.c_bool
    user32.EmptyClipboard.argtypes = []
    user32.EmptyClipboard.restype = ctypes.c_bool
    user32.SetClipboardData.argtypes = [ctypes.c_uint, ctypes.c_void_p]
    user32.SetClipboardData.restype = ctypes.c_void_p
    user32.CloseClipboard.argtypes = []
    user32.CloseClipboard.restype = ctypes.c_bool
    kernel32.GlobalAlloc.argtypes = [ctypes.c_uint, ctypes.c_size_t]
    kernel32.GlobalAlloc.restype = ctypes.c_void_p
    kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
    kernel32.GlobalLock.restype = ctypes.c_void_p
    kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]
    kernel32.GlobalUnlock.restype = ctypes.c_bool
    kernel32.GlobalFree.argtypes = [ctypes.c_void_p]
    kernel32.GlobalFree.restype = ctypes.c_void_p

    last_error: Exception | None = None
    for _ in range(5):
        memory_handle = None
        clipboard_open = bool(user32.OpenClipboard(None))
        if not clipboard_open:
            last_error = RuntimeError('OpenClipboard failed.')
            time.sleep(0.1)
            continue

        try:
            if not user32.EmptyClipboard():
                raise RuntimeError('EmptyClipboard failed.')

            memory_handle = kernel32.GlobalAlloc(gmem_moveable, len(dib_bytes))
            if not memory_handle:
                raise RuntimeError('GlobalAlloc failed.')

            locked_memory = kernel32.GlobalLock(memory_handle)
            if not locked_memory:
                raise RuntimeError('GlobalLock failed.')

            try:
                ctypes.memmove(locked_memory, dib_bytes, len(dib_bytes))
            finally:
                kernel32.GlobalUnlock(memory_handle)

            if not user32.SetClipboardData(cf_dib, memory_handle):
                raise RuntimeError('SetClipboardData(CF_DIB) failed.')

            memory_handle = None
            return
        except Exception as error:
            last_error = error
        finally:
            if memory_handle:
                kernel32.GlobalFree(memory_handle)
            user32.CloseClipboard()

        time.sleep(0.1)

    raise RuntimeError(f'Unable to place image onto the clipboard: {last_error}') from last_error


def _extract_json(text: str) -> dict[str, Any]:
    stripped = text.strip()
    if stripped.startswith('```'):
        fenced_match = re.search(r'```(?:json)?\s*(.*?)\s*```', stripped, re.DOTALL)
        if fenced_match:
            stripped = fenced_match.group(1).strip()
        else:
            stripped = re.sub(r'^```(?:json)?\s*', '', stripped)
            stripped = re.sub(r'\s*```$', '', stripped)

    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        decoder = json.JSONDecoder()
        for index, character in enumerate(stripped):
            if character not in '{[':
                continue

            try:
                parsed, _ = decoder.raw_decode(stripped[index:])
                if isinstance(parsed, dict):
                    return parsed
            except json.JSONDecodeError:
                continue
        raise


def _contains_text(ocr_items: list[dict[str, Any]], *needles: str) -> bool:
    haystack = ' '.join(str(item.get('text', '')).lower() for item in ocr_items)
    return any(needle.lower() in haystack for needle in needles)


def _normalize_text(text: str) -> str:
    return re.sub(r'[\W_]+', '', text.casefold())


def _is_generic_delivery_instruction(text: str) -> bool:
    normalized = _normalize_text(text)
    return normalized in {
        '复制文本内容就行',
        '复制文本就行',
        '复制内容就行',
        '复制就行',
        '发给他就行',
        '发给就行',
    }


def _prompt_requests_link_delivery(user_prompt: str) -> bool:
    normalized = user_prompt.casefold()
    return 'github' in normalized and (
        '代码链接' in user_prompt
        or 'link' in normalized
        or 'http://github.com/' in normalized
        or 'https://github.com/' in normalized
    )


def _extract_teams_target(user_prompt: str) -> dict[str, str]:
    normalized_prompt = _strip_control_tokens(user_prompt).strip()

    chinese_no_message_match = re.search(r'给\s*(.+?)\s*发送\s*$', normalized_prompt, re.IGNORECASE)
    if chinese_no_message_match:
        return {
            'contact': chinese_no_message_match.group(1).strip(),
            'message': '',
        }

    chinese_match = re.search(r'给\s*(.+?)\s*发送\s*(.+)$', normalized_prompt, re.IGNORECASE)
    if chinese_match:
        message = chinese_match.group(2).strip()
        if _is_generic_delivery_instruction(message):
            message = ''
        return {
            'contact': chinese_match.group(1).strip(),
            'message': message,
        }

    send_to_match = re.search(
        r'发给\s*(.+?)(?:\s+(复制文本内容就行|复制文本就行|复制内容就行|复制就行|就行)\s*)?$',
        normalized_prompt,
        re.IGNORECASE,
    )
    if send_to_match:
        message = str(send_to_match.group(2) or '').strip()
        if _is_generic_delivery_instruction(message):
            message = ''
        return {
            'contact': send_to_match.group(1).strip(),
            'message': message,
        }

    english_match = re.search(r'send\s+(.+?)\s+to\s+(.+)$', normalized_prompt, re.IGNORECASE)
    if english_match:
        message = english_match.group(1).strip()
        if _is_generic_delivery_instruction(message):
            message = ''
        return {
            'contact': english_match.group(2).strip(),
            'message': message,
        }

    return {
        'contact': '',
        'message': '',
    }


def _find_ocr_item(ocr_items: list[dict[str, Any]], target: str) -> dict[str, Any] | None:
    normalized_target = _normalize_text(target)
    if not normalized_target:
        return None

    exact_match: dict[str, Any] | None = None
    partial_match: dict[str, Any] | None = None
    for item in ocr_items:
        text = str(item.get('text', '')).strip()
        normalized_text = _normalize_text(text)
        if not normalized_text:
            continue

        if normalized_text == normalized_target:
            return item

        if normalized_target in normalized_text or normalized_text in normalized_target:
            if exact_match is None:
                exact_match = item
                continue

        if partial_match is None and all(part in normalized_text for part in re.findall(r'[a-z0-9]+', normalized_target)):
            partial_match = item

    return exact_match or partial_match


def _find_visible_window_title(window_snapshot: dict[str, Any], *needles: str) -> str:
    normalized_needles = [_normalize_text(needle) for needle in needles if needle]
    if not normalized_needles:
        return ''

    for title in (window_snapshot.get('visibleTitles') or []):
        current_title = str(title).strip()
        normalized_title = _normalize_text(current_title)
        if normalized_title and all(needle in normalized_title for needle in normalized_needles):
            return current_title

    return ''


def _infer_teams_compose_box(window_snapshot: dict[str, Any], screen_width: int, screen_height: int) -> dict[str, Any] | None:
    active_title = _normalize_text(str(window_snapshot.get('activeTitle', '')))
    if 'teams' not in active_title:
        return None

    if screen_width <= 0 or screen_height <= 0:
        return None

    active_bounds = window_snapshot.get('activeBounds') or {}
    bounds_left = int(active_bounds.get('left', 0) or 0)
    bounds_top = int(active_bounds.get('top', 0) or 0)
    bounds_width = int(active_bounds.get('width', 0) or 0)
    bounds_height = int(active_bounds.get('height', 0) or 0)

    if bounds_width > 0 and bounds_height > 0:
        center_x = bounds_left + int(bounds_width * 0.58)
        center_y = bounds_top + int(bounds_height * 0.94)
    else:
        center_x = int(screen_width * 0.58)
        center_y = int(screen_height * 0.94)

    return {
        'text': 'inferred teams compose box',
        'score': 0.0,
        'centerX': max(1, min(center_x, screen_width - 1)),
        'centerY': max(1, min(center_y, screen_height - 1)),
    }


def _has_message_compose_box(
    ocr_items: list[dict[str, Any]],
    screen_height: int,
    screen_width: int = 0,
    window_snapshot: dict[str, Any] | None = None,
) -> dict[str, Any] | None:
    lower_screen_boundary = int(screen_height * 0.72)

    for candidate in (
        'type a message',
        'write a message',
        'message compose box',
        'compose box',
    ):
        match = _find_ocr_item(ocr_items, candidate)
        if match is not None and int(match.get('centerY', 0)) >= lower_screen_boundary:
            return match

    for item in ocr_items:
        text = str(item.get('text', '')).strip().lower()
        center_y = int(item.get('centerY', 0))
        if center_y < lower_screen_boundary:
            continue

        if 'type a message' in text or 'write a message' in text:
            return item

    if window_snapshot is not None:
        return _infer_teams_compose_box(window_snapshot, screen_width, screen_height)

    return None


def _has_sent_message_from_you(ocr_items: list[dict[str, Any]], target_message: str) -> bool:
    normalized_message = _normalize_text(target_message)
    if not normalized_message:
        return False

    for item in ocr_items:
        text = str(item.get('text', '')).strip()
        normalized_text = _normalize_text(text)
        if normalized_message not in normalized_text:
            continue

        if normalized_text.startswith('you') or normalized_text.startswith('jacklinyou'):
            return True

    return False


def _has_recent_sent_link_message(ocr_items: list[dict[str, Any]], compose_y: int, target_message: str = '') -> bool:
    normalized_target = _normalize_text(target_message)
    target_prefix = ''
    if normalized_target:
        target_prefix = normalized_target.split('https', 1)[0].strip(' :')

    for item in ocr_items:
        text = str(item.get('text', '')).strip()
        normalized_text = _normalize_text(text)
        if not normalized_text:
            continue

        center_y = int(item.get('centerY', 0))
        if center_y < compose_y - 160:
            continue
        if center_y >= compose_y:
            continue

        has_link_shape = any(
            token in normalized_text
            for token in ('github', 'ithub', 'blob', 'wisetechglobal', 'cargowise', 'https')
        )
        looks_like_code_link_message = '.cs' in normalized_text or normalized_text.startswith('you')
        if 'github.com/' in text.casefold():
            return True
        if has_link_shape and looks_like_code_link_message:
            return True
        if target_prefix and target_prefix in normalized_text:
            return True

    return False


def _post_send_completed(
    user_prompt: str,
    ocr_items: list[dict[str, Any]],
    window_snapshot: dict[str, Any],
    screen_width: int,
    screen_height: int,
) -> bool:
    target = _extract_teams_target(user_prompt)
    target_contact = target['contact']
    target_message = _extract_media_text(user_prompt) or target['message']
    media_path = _extract_media_path(user_prompt)
    active_title = str(window_snapshot.get('activeTitle', ''))

    if not target_contact:
        return False

    if _normalize_text(target_contact) not in _normalize_text(active_title):
        return False

    compose_box = _has_message_compose_box(ocr_items, screen_height, screen_width, window_snapshot)
    if compose_box is None:
        return False

    if media_path:
        return True

    if target_message and _has_sent_message_from_you(ocr_items, target_message):
        return True

    compose_y = int(compose_box.get('centerY', 0))
    if _prompt_requests_link_delivery(user_prompt) and _has_recent_sent_link_message(ocr_items, compose_y, target_message):
        return True

    normalized_message = _normalize_text(target_message)
    if not normalized_message:
        return False

    for item in ocr_items:
        normalized_text = _normalize_text(str(item.get('text', '')))
        if not normalized_text or normalized_message not in normalized_text:
            continue

        center_y = int(item.get('centerY', 0))
        if center_y < compose_y - 120:
            return True

    return False


def _try_finish_teams_send_after_actions(
    user_prompt: str,
    ocr_items: list[dict[str, Any]],
    window_snapshot: dict[str, Any],
    screen_width: int,
    screen_height: int,
) -> bool:
    target = _extract_teams_target(user_prompt)
    target_contact = target['contact']
    target_message = _extract_media_text(user_prompt) or target['message']
    media_path = _extract_media_path(user_prompt)
    active_title = str(window_snapshot.get('activeTitle', ''))

    if not target_contact or (not target_message and not media_path):
        return False

    if 'teams' not in active_title.lower():
        return False

    if _normalize_text(target_contact) not in _normalize_text(active_title):
        return False

    if _post_send_completed(user_prompt, ocr_items, window_snapshot, screen_width, screen_height):
        return True

    time.sleep(0.4)
    verification_path = _capture_screenshot_file()
    verification_width, verification_height = _screen_size()
    verification_ocr_items = _ocr_screen(verification_path)
    verification_window_snapshot = _get_window_snapshot()
    return _post_send_completed(
        user_prompt,
        verification_ocr_items,
        verification_window_snapshot,
        verification_width,
        verification_height,
    )


def _build_bootstrap_plan(
    user_prompt: str,
    ocr_items: list[dict[str, Any]],
    window_snapshot: dict[str, Any],
    screen_width: int,
    screen_height: int,
) -> dict[str, Any] | None:
    normalized_prompt = user_prompt.lower()
    target = _extract_teams_target(user_prompt)
    target_contact = target['contact']
    target_message = _extract_media_text(user_prompt) or target['message']
    media_path = _extract_media_path(user_prompt)
    active_title = str(window_snapshot.get('activeTitle', '')).lower()
    visible_titles = [str(title) for title in (window_snapshot.get('visibleTitles') or [])]
    has_teams_window = any('teams' in title.lower() for title in visible_titles)
    target_in_active_title = bool(target_contact) and _normalize_text(target_contact) in _normalize_text(active_title)
    target_chat_window_title = _find_visible_window_title(window_snapshot, target_contact, 'teams') if target_contact else ''

    if target_chat_window_title and _normalize_text(target_chat_window_title) != _normalize_text(active_title):
        return {
            'done': False,
            'summary': f'Activating the existing Teams chat window for {target_contact}.',
            'actions': [
                {'type': 'activate_window', 'title': target_chat_window_title},
                {'type': 'maximize_window', 'title': target_chat_window_title},
                {'type': 'wait_for_window', 'title': target_chat_window_title, 'timeoutSeconds': 5},
            ],
        }

    if target_in_active_title and _has_sent_message_from_you(ocr_items, target_message):
        return {
            'done': True,
            'summary': f'The requested message has already been sent to {target_contact}.',
            'actions': [],
        }

    compose_box = _has_message_compose_box(ocr_items, screen_height, screen_width, window_snapshot)
    if target_in_active_title and compose_box is not None and media_path:
        actions: list[dict[str, Any]] = [
            {'type': 'click', 'x': int(compose_box['centerX']), 'y': int(compose_box['centerY']), 'button': 'left'},
        ]
        if target_message:
            actions.extend(
                [
                    {'type': 'type', 'text': target_message},
                    {'type': 'keypress', 'keys': ['shift', 'enter']},
                ]
            )
        actions.extend(
            [
                {'type': 'paste_image', 'path': media_path},
                {'type': 'wait'},
                {'type': 'keypress', 'keys': ['enter']},
            ]
        )
        return {
            'done': False,
            'summary': f'Sending the requested image to {target_contact}.',
            'actions': actions,
        }

    if target_in_active_title and compose_box is not None and target_message:
        return {
            'done': False,
            'summary': f'Sending the requested message to {target_contact}.',
            'actions': [
                {'type': 'click', 'x': int(compose_box['centerX']), 'y': int(compose_box['centerY']), 'button': 'left'},
                {'type': 'type', 'text': target_message},
                {'type': 'keypress', 'keys': ['enter']},
            ],
        }

    if target_in_active_title and not target_message:
        return None

    if target_in_active_title and target_message:
        return {
            'done': False,
            'summary': f'Waiting for a safe message input area in the Teams chat for {target_contact}.',
            'actions': [
                {'type': 'wait'},
            ],
        }

    contact_result = _find_ocr_item(ocr_items, target_contact)
    if contact_result is not None and target_contact and not target_in_active_title and 'teams' in active_title:
        return {
            'done': False,
            'summary': f'Opening the search result for {target_contact}.',
            'actions': [
                {'type': 'click', 'x': int(contact_result['centerX']), 'y': int(contact_result['centerY']), 'button': 'left'},
                {'type': 'wait'},
                {'type': 'wait_for_window', 'title': target_contact, 'timeoutSeconds': 10},
            ],
        }

    if 'teams' in normalized_prompt and has_teams_window and 'teams' not in active_title:
        return {
            'done': False,
            'summary': 'Activating existing Microsoft Teams window.',
            'actions': [
                {'type': 'activate_window', 'title': 'Teams'},
                {'type': 'maximize_window', 'title': 'Teams'},
                {'type': 'wait_for_window', 'title': 'Teams', 'timeoutSeconds': 5},
            ],
        }

    if (
        'teams' in normalized_prompt
        and not has_teams_window
        and 'teams' not in active_title
        and not _contains_text(ocr_items, 'teams', 'microsoft teams')
    ):
        return {
            'done': False,
            'summary': 'Launching Microsoft Teams from Windows search.',
            'actions': [
                {'type': 'keypress', 'keys': ['win']},
                {'type': 'wait'},
                {'type': 'type', 'text': 'Microsoft Teams'},
                {'type': 'keypress', 'keys': ['enter']},
                {'type': 'wait'},
                {'type': 'wait_for_window', 'title': 'Teams', 'timeoutSeconds': 15},
            ],
        }

    if 'teams' in normalized_prompt and target_contact:
        return {
            'done': False,
            'summary': f'Searching Teams for {target_contact}.',
            'actions': [
                {'type': 'activate_window', 'title': 'Teams'},
                {'type': 'keypress', 'keys': ['ctrl', 'e']},
                {'type': 'type', 'text': target_contact},
                {'type': 'wait'},
            ],
        }

    return None


def _run_gh_copilot(prompt: str, repo_path: str, model: str | None) -> dict[str, Any]:
    prompt_dir = Path(repo_path) / 'plugins' / 'personal' / 'wechat-copilot-bridge' / 'logs'
    prompt_dir.mkdir(parents=True, exist_ok=True)
    prompt_path = prompt_dir / 'gh-computer-use-prompt.json'
    prompt_path.write_text(prompt, encoding='utf-8')

    wrapper_prompt = (
        f"Read the file at {prompt_path} and follow it exactly. "
        'Return exactly one JSON object and nothing else.'
    )

    command = [
        'gh',
        'copilot',
        '--',
        '-p',
        wrapper_prompt,
        '-s',
        '--allow-all-tools',
        '--no-color',
        '--no-ask-user',
        '--add-dir',
        repo_path,
        '--add-dir',
        str(prompt_dir),
    ]

    if model:
        command.extend(['--model', model])

    result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', errors='replace')
    if result.returncode != 0:
        error_text = (result.stderr or result.stdout or 'gh copilot failed').strip()
        raise RuntimeError(error_text)

    return _extract_json(result.stdout)


def _build_prompt(user_prompt: str, screenshot_path: Path, ocr_items: list[dict[str, Any]], width: int, height: int, window_snapshot: dict[str, Any]) -> str:
    visible_items = [item for item in ocr_items if item['text'].strip()]
    visible_items = visible_items[:120]

    instructions = {
        'task': user_prompt,
        'screen': {
            'width': width,
            'height': height,
            'screenshotPath': str(screenshot_path),
            'ocrItems': visible_items,
            'activeWindowTitle': str(window_snapshot.get('activeTitle', '')),
            'visibleWindowTitles': list(window_snapshot.get('visibleTitles') or []),
        },
        'requirements': [
            'Return exactly one JSON object and nothing else.',
            'Use only these action types: click, double_click, move, drag, scroll, type, keypress, wait, activate_window, maximize_window, wait_for_window, paste_image.',
            'Keep actions minimal for the next step only; do not plan many risky actions at once.',
            'If the task is complete, set done=true and actions=[].',
            'If there is not enough evidence from OCR text, prefer safe navigation or wait instead of guessing.',
            'Do not embed special keys inside type text. Use keypress for Enter, Tab, Escape, arrows, shortcuts, and hotkeys.',
            'For keypress, return keys as an array like ["ctrl","l"].',
            'For scroll, include x, y, scroll_x, scroll_y.',
            'Use paste_image only with a local image file path that already exists on disk.',
            'Prefer window actions before coordinate clicks when the target app window is known.',
            'When an app is already open but not focused, use activate_window before further actions.',
        ],
        'responseSchema': {
            'done': 'boolean',
            'summary': 'string',
            'actions': [
                {
                    'type': 'click|double_click|move|drag|scroll|type|keypress|wait|activate_window|maximize_window|wait_for_window|paste_image',
                    'x': 'number when needed',
                    'y': 'number when needed',
                    'button': 'left|right|wheel when needed',
                    'path': [{'x': 'number', 'y': 'number'}],
                    'scroll_x': 'number',
                    'scroll_y': 'number',
                    'text': 'string',
                    'keys': ['string'],
                    'title': 'string',
                    'timeoutSeconds': 'number',
                    'pathString': 'local image path for paste_image',
                }
            ],
        },
    }
    return json.dumps(instructions, ensure_ascii=False)


def _execute_action(action: dict[str, Any]) -> None:
    action_type = action.get('type')
    if action_type == 'click':
        pyautogui.click(int(action['x']), int(action['y']), button=_map_button(action.get('button')))
        return
    if action_type == 'double_click':
        pyautogui.doubleClick(int(action['x']), int(action['y']))
        return
    if action_type == 'move':
        pyautogui.moveTo(int(action['x']), int(action['y']))
        return
    if action_type == 'drag':
        path = action.get('path') or []
        if not path:
            return
        first = path[0]
        pyautogui.moveTo(int(first['x']), int(first['y']))
        pyautogui.mouseDown()
        try:
            for point in path[1:]:
                pyautogui.dragTo(int(point['x']), int(point['y']), duration=0.1, button='left')
        finally:
            pyautogui.mouseUp()
        return
    if action_type == 'scroll':
        pyautogui.moveTo(int(action['x']), int(action['y']))
        scroll_y = int(action.get('scroll_y', 0))
        if scroll_y != 0:
            pyautogui.scroll(scroll_y, x=int(action['x']), y=int(action['y']))
        scroll_x = int(action.get('scroll_x', 0))
        if scroll_x != 0 and hasattr(pyautogui, 'hscroll'):
            pyautogui.hscroll(scroll_x, x=int(action['x']), y=int(action['y']))
        return
    if action_type == 'type':
        _type_text_with_tokens(str(action.get('text', '')))
        return
    if action_type == 'keypress':
        keys = [_map_key(str(key)) for key in (action.get('keys') or [])]
        if not keys:
            return
        if len(keys) == 1:
            pyautogui.press(keys[0])
        else:
            pyautogui.hotkey(*keys)
        return
    if action_type == 'paste_image':
        _copy_image_file_to_clipboard(str(action.get('path', '')))
        time.sleep(0.1)
        pyautogui.hotkey('ctrl', 'v')
        return
    if action_type == 'activate_window':
        _activate_window_by_title(str(action.get('title', '')))
        return
    if action_type == 'maximize_window':
        _maximize_window_by_title(str(action.get('title', '')))
        return
    if action_type == 'wait_for_window':
        _wait_for_window(str(action.get('title', '')), float(action.get('timeoutSeconds', 10)))
        return
    if action_type == 'wait':
        time.sleep(1.0)
        return
    raise ValueError(f'Unsupported action type: {action_type}')


def main() -> int:
    parser = argparse.ArgumentParser(description='Run a local GitHub CLI plus OCR plus pyautogui control loop.')
    parser.add_argument('--prompt', required=True)
    parser.add_argument('--repo', required=False, default='')
    parser.add_argument('--model', default='')
    parser.add_argument('--max-turns', type=int, default=3)
    args = parser.parse_args()

    for turn in range(max(args.max_turns, 1)):
        screenshot_path = _capture_screenshot_file()
        width, height = _screen_size()
        ocr_items = _ocr_screen(screenshot_path)
        window_snapshot = _get_window_snapshot()
        plan = _build_bootstrap_plan(args.prompt, ocr_items, window_snapshot, width, height)
        if plan is None:
            prompt = _build_prompt(args.prompt, screenshot_path, ocr_items, width, height, window_snapshot)
            plan = _run_gh_copilot(prompt, args.repo or os.getcwd(), args.model or None)

        actions = plan.get('actions') or []
        done = bool(plan.get('done'))
        summary = str(plan.get('summary', '')).strip()

        _append_debug_log(
            {
                'timestamp': time.strftime('%Y-%m-%dT%H:%M:%S'),
                'turn': turn,
                'prompt': args.prompt,
                'windowSnapshot': window_snapshot,
                'ocrItems': ocr_items[:80],
                'plan': plan,
                'done': done,
                'summary': summary,
                'screenshotPath': str(screenshot_path),
            },
            args.repo or os.getcwd(),
        )

        if done or not actions:
            print(summary or 'GitHub CLI computer-use runner completed.')
            return 0

        for action in actions:
            _execute_action(action)

        screenshot_path = _capture_screenshot_file()
        post_width, post_height = _screen_size()
        post_ocr_items = _ocr_screen(screenshot_path)
        post_window_snapshot = _get_window_snapshot()
        if _try_finish_teams_send_after_actions(args.prompt, post_ocr_items, post_window_snapshot, post_width, post_height):
            target = _extract_teams_target(args.prompt)
            contact = target['contact'] or 'the target contact'
            print(f'The requested message has been sent to {contact}.')
            return 0

        if _post_send_completed(args.prompt, post_ocr_items, post_window_snapshot, post_width, post_height):
            target = _extract_teams_target(args.prompt)
            contact = target['contact'] or 'the target contact'
            print(f'The requested message has been sent to {contact}.')
            return 0

        time.sleep(0.5)

    print(f'GitHub CLI computer-use runner exceeded max turns ({args.max_turns}).', file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())