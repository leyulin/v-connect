# WeChat Copilot Bridge PoC

This is a local-only prototype for the flow:

`WeChat adapter -> local HTTP bridge -> Copilot CLI or local GitHub CLI + pyautogui runner`

The bridge does not include a real personal WeChat adapter yet. Instead, it
exposes a local HTTP endpoint that a future adapter can call.

## What Works In V1

- `POST /message` routes requests to `copilot.ps1` in non-interactive mode
- Requests are constrained to the current `WTG.AI.Prompts` repo path
- The bridge supports two modes:
  - `read`: analysis only
  - `apply`: Copilot may edit repo files
- GUI-intent requests can be routed to a local GitHub CLI + OCR + pyautogui runner
- A local test client script is included
- The bridge persists recent session and media runtime state to a local JSON file

## Files

- `Start-CopilotWechatBridge.ps1` - starts the local HTTP bridge
- `Start-GitHubCliComputerUseRunner.py` - runs a local screenshot + OCR + GitHub CLI + pyautogui loop against the desktop
- `Invoke-CopilotWechatBridgeMessage.ps1` - posts a test message locally
- `Start-CcConnectPersonalWechatAdapter.ps1` - polls personal WeChat updates and forwards them to the bridge
- `config.sample.json` - sample configuration
- `adapter.sample.json` - sample adapter configuration
- `mock-updates.sample.json` - local mock update payload for adapter validation
- `logs/bridge-runtime-state.json` - recent sessions and cached media metadata, created on first run

## Quick Start

1. Copy `config.sample.json` to `config.json` if you want a separate local config.
2. Start the bridge:

```powershell
./Start-CopilotWechatBridge.ps1 -ConfigPath ./config.sample.json
```

3. In another terminal, send a test message:

```powershell
./Invoke-CopilotWechatBridgeMessage.ps1 -Text 'Summarize the purpose of this repository'
```

4. To allow edits, use apply mode:

```powershell
./Invoke-CopilotWechatBridgeMessage.ps1 -Mode apply -Text 'Create a short draft README under plugins/personal/test-output'
```

5. To test the GUI route with the local GitHub CLI runner:

```powershell
./Invoke-CopilotWechatBridgeMessage.ps1 -Route gui -Text 'Open VS Code and take a screenshot'
```

## Minimal Personal WeChat Entry

This adapter targets the personal-WeChat path discussed earlier: a `cc-connect`
style bot endpoint that exposes `getUpdates` and `sendMessage` semantics.

For now, the adapter supports two input modes:

- Real polling mode: uses `wechat.baseUrl` and `wechat.botToken`
- Mock mode: reads `mock-updates.sample.json` and writes outbound replies to a local JSONL file

### Mock Validation

1. Start the bridge:

```powershell
./Start-CopilotWechatBridge.ps1 -ConfigPath ./config.sample.json -MaxRequests 1
```

2. Run the adapter once in mock mode:

```powershell
./Start-CcConnectPersonalWechatAdapter.ps1 -ConfigPath ./adapter.sample.json -RunOnce
```

3. Inspect the outbound mock reply sink:

```powershell
Get-Content ./mock-sent-replies.jsonl
```

If the chain works, the reply body will contain `ADAPTER_OK`.

### Real Polling Mode

To switch to a real personal WeChat source:

1. Set `mock.enabled` to `false` in `adapter.sample.json`
2. Fill in:
  - `wechat.baseUrl`
  - `wechat.botToken`
3. Start the bridge
4. Start the adapter without `-RunOnce`

The adapter will:

- poll `getUpdates`
- forward text messages to `/message`
- send the bridge reply back with `sendMessage`
- persist `lastUpdateId` in `adapter-state.json`
- retain a bounded recent-media index for image follow-up commands such as Teams sends

## HTTP Contract

### `GET /health`

Returns bridge health and current configuration summary.

### `POST /message`

Request body:

```json
{
  "text": "Summarize this repo",
  "userId": "local-user",
  "sessionId": "wechat-demo",
  "mode": "read"
}
```

Optional fields:

- `route: "gui"` to force the GUI fallback route
- `mode: "apply"` to allow file changes

## Runtime State

The bridge now persists lightweight runtime state so that recent session activity
and cached media survive a restart.

- `storage.runtimeStatePath` controls where the bridge stores runtime state
- `storage.sessionRetentionHours` and `storage.maxSessionEntries` bound recent session history
- `storage.mediaRetentionHours` and `storage.maxMediaEntries` bound cached media metadata
- `storage.latestMediaRetentionHours` and `storage.latestMediaMaxEntries` bound the adapter-side latest-media index

`GET /health` now includes runtime-state counts so you can verify whether the
bridge still has recent session/media context loaded.

## Notes

- The bridge is single-machine and local-only.
- It does not push git changes.
- It explicitly denies `git push` through Copilot CLI arguments.
- The GUI route is optional. If `computerUse.command` is empty, the bridge returns a
  structured message saying the local GitHub CLI runner is not configured yet.
- The local runner requires a working `gh copilot` CLI login and Python packages `pyautogui`, `pillow`, and `rapidocr-onnxruntime` in the repo virtual environment.