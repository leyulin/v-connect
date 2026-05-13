#!/usr/bin/env pwsh
<#!
.SYNOPSIS
Starts a local HTTP bridge that routes incoming messages to Copilot CLI.

.DESCRIPTION
Exposes a local-only HTTP endpoint for a future WeChat adapter. Incoming POST
requests are routed to Copilot CLI by default. Requests that clearly need GUI
automation can optionally be forwarded to a separately configured runner.

.PARAMETER ConfigPath
Path to the bridge configuration JSON file.

.PARAMETER MaxRequests
Maximum number of requests to process before exiting. Use 0 for unlimited.

.EXAMPLE
./Start-CopilotWechatBridge.ps1 -ConfigPath ./config.sample.json

.EXAMPLE
./Start-CopilotWechatBridge.ps1 -ConfigPath ./config.sample.json -MaxRequests 2
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [ValidateRange(0, 1000000)]
    [int]$MaxRequests = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:MissingTeamsImageReply = '还没有可发送的最近图片。请先在微信发一张图片，再发：打开我的teams 给某人发送'
$script:DefaultRuntimeStateRelativePath = (Join-Path 'logs' 'bridge-runtime-state.json')
$script:DefaultRuntimeSessionRetentionHours = 24
$script:DefaultRuntimeMediaRetentionHours = 24
$script:DefaultRuntimeMaxSessionEntries = 200
$script:DefaultRuntimeMaxMediaEntries = 100

function New-DefaultBridgeRuntimeState {
    return [PSCustomObject]@{
        sessions = @()
        mediaEntries = @()
    }
}

function Get-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Resolve-NormalizedPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return [System.IO.Path]::GetFullPath($Path)
}

function Get-BridgeConfig {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Bridge config not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    $config = $raw | ConvertFrom-Json
    if ($null -eq $config) {
        throw "Bridge config is empty: $Path"
    }

    if ([string]::IsNullOrWhiteSpace($config.server.prefix)) {
        throw 'Config value server.prefix is required.'
    }
    if ([string]::IsNullOrWhiteSpace($config.repo.path)) {
        throw 'Config value repo.path is required.'
    }
    if ([string]::IsNullOrWhiteSpace($config.copilot.command)) {
        throw 'Config value copilot.command is required.'
    }

    $config.repo.path = Resolve-NormalizedPath -Path $config.repo.path

    if (-not (Test-Path -LiteralPath $config.repo.path)) {
        throw "Configured repo.path does not exist: $($config.repo.path)"
    }

    $logDirectory = [string](Get-OptionalPropertyValue -InputObject $config.logging -Name 'directory' -DefaultValue 'logs')
    if (-not [System.IO.Path]::IsPathRooted($logDirectory)) {
        $logDirectory = Resolve-NormalizedPath -Path (Join-Path $PSScriptRoot $logDirectory)
    }
    $config.logging.directory = $logDirectory

    if ($config.PSObject.Properties.Match('storage').Count -eq 0 -or $null -eq $config.storage) {
        $config | Add-Member -NotePropertyName storage -NotePropertyValue ([PSCustomObject]@{})
    }

    $runtimeStatePath = [string](Get-OptionalPropertyValue -InputObject $config.storage -Name 'runtimeStatePath' -DefaultValue (Join-Path $PSScriptRoot $script:DefaultRuntimeStateRelativePath))
    if (-not [System.IO.Path]::IsPathRooted($runtimeStatePath)) {
        $runtimeStatePath = Resolve-NormalizedPath -Path (Join-Path $PSScriptRoot $runtimeStatePath)
    }
    $config.storage.runtimeStatePath = $runtimeStatePath

    return $config
}

function ConvertTo-BridgeJson {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject
    )

    return $InputObject | ConvertTo-Json -Depth 8
}

function Get-OptionalPropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,
        [Parameter(Mandatory)]
        [string]$Name,
        $DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    if ($InputObject.PSObject.Properties.Match($Name).Count -eq 0) {
        return $DefaultValue
    }

    return $InputObject.$Name
}

function Get-BridgeRetentionHours {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [string]$Name,
        [ValidateRange(1, 8760)]
        [int]$DefaultValue
    )

    $value = [int](Get-OptionalPropertyValue -InputObject $Config.storage -Name $Name -DefaultValue $DefaultValue)
    if ($value -lt 1) {
        return $DefaultValue
    }

    return $value
}

function Get-BridgeMaxEntryCount {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [string]$Name,
        [ValidateRange(1, 100000)]
        [int]$DefaultValue
    )

    $value = [int](Get-OptionalPropertyValue -InputObject $Config.storage -Name $Name -DefaultValue $DefaultValue)
    if ($value -lt 1) {
        return $DefaultValue
    }

    return $value
}

function ConvertTo-UtcDateTime {
    param(
        [AllowEmptyString()]
        [string]$Value,
        [Parameter(Mandatory)]
        [datetime]$DefaultValue
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $DefaultValue
    }

    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return $parsed.UtcDateTime
    }

    return $DefaultValue
}

function Get-BridgeRuntimeState {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return New-DefaultBridgeRuntimeState
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    $state = $raw | ConvertFrom-Json
    if ($null -eq $state) {
        return New-DefaultBridgeRuntimeState
    }

    if ($state.PSObject.Properties.Match('sessions').Count -eq 0) {
        $state | Add-Member -NotePropertyName sessions -NotePropertyValue @()
    }

    if ($state.PSObject.Properties.Match('mediaEntries').Count -eq 0) {
        $state | Add-Member -NotePropertyName mediaEntries -NotePropertyValue @()
    }

    return $state
}

function Save-BridgeRuntimeState {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [object]$RuntimeState
    )

    $directoryPath = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directoryPath) -and -not (Test-Path -LiteralPath $directoryPath)) {
        New-Item -ItemType Directory -Path $directoryPath -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, (ConvertTo-BridgeJson -InputObject $RuntimeState), (Get-Utf8NoBomEncoding))
}

function Invoke-BridgeRuntimeMaintenance {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [object]$RuntimeState
    )

    $nowUtc = [datetime]::UtcNow
    $sessionCutoffUtc = $nowUtc.AddHours(-1 * (Get-BridgeRetentionHours -Config $Config -Name 'sessionRetentionHours' -DefaultValue $script:DefaultRuntimeSessionRetentionHours))
    $mediaCutoffUtc = $nowUtc.AddHours(-1 * (Get-BridgeRetentionHours -Config $Config -Name 'mediaRetentionHours' -DefaultValue $script:DefaultRuntimeMediaRetentionHours))
    $maxSessionEntries = Get-BridgeMaxEntryCount -Config $Config -Name 'maxSessionEntries' -DefaultValue $script:DefaultRuntimeMaxSessionEntries
    $maxMediaEntries = Get-BridgeMaxEntryCount -Config $Config -Name 'maxMediaEntries' -DefaultValue $script:DefaultRuntimeMaxMediaEntries

    $RuntimeState.sessions = @($RuntimeState.sessions | Where-Object {
        (ConvertTo-UtcDateTime -Value ([string](Get-OptionalPropertyValue -InputObject $_ -Name 'lastActivityAt' -DefaultValue '')) -DefaultValue ([datetime]::MinValue)) -ge $sessionCutoffUtc
    } | Sort-Object {
        ConvertTo-UtcDateTime -Value ([string](Get-OptionalPropertyValue -InputObject $_ -Name 'lastActivityAt' -DefaultValue '')) -DefaultValue ([datetime]::MinValue)
    } -Descending | Select-Object -First $maxSessionEntries)

    $RuntimeState.mediaEntries = @($RuntimeState.mediaEntries | Where-Object {
        $timestampUtc = ConvertTo-UtcDateTime -Value ([string](Get-OptionalPropertyValue -InputObject $_ -Name 'timestamp' -DefaultValue '')) -DefaultValue ([datetime]::MinValue)
        $path = [string](Get-OptionalPropertyValue -InputObject $_ -Name 'path' -DefaultValue '')
        $timestampUtc -ge $mediaCutoffUtc -and -not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)
    } | Sort-Object {
        ConvertTo-UtcDateTime -Value ([string](Get-OptionalPropertyValue -InputObject $_ -Name 'timestamp' -DefaultValue '')) -DefaultValue ([datetime]::MinValue)
    } -Descending | Select-Object -First $maxMediaEntries)
}

function Resolve-CommandPath {
    param(
        [Parameter(Mandatory)]
        [string]$Command
    )

    if (Test-Path -LiteralPath $Command) {
        return Resolve-NormalizedPath -Path $Command
    }

    $candidates = @(Get-Command $Command -All -ErrorAction Stop)
    if ($candidates.Count -eq 0) {
        throw "Command not found: $Command"
    }

    $resolved = $candidates |
        Sort-Object -Property @{ Expression = {
            $source = [string]$_.Source
            if ($source.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) { return 0 }
            if ($source.EndsWith('.cmd', [System.StringComparison]::OrdinalIgnoreCase)) { return 1 }
            if ($source.EndsWith('.bat', [System.StringComparison]::OrdinalIgnoreCase)) { return 2 }
            if ($source.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) { return 4 }
            return 3
        }}, @{ Expression = { [string]$_.Source } } |
        Select-Object -First 1

    if (-not [string]::IsNullOrWhiteSpace([string]$resolved.Source)) {
        return [string]$resolved.Source
    }

    return [string]$resolved.Name
}

function Write-JsonResponse {
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory)]
        [int]$StatusCode,
        [Parameter(Mandatory)]
        [object]$Body
    )

    $json = ConvertTo-BridgeJson -InputObject $Body
    $buffer = (Get-Utf8NoBomEncoding).GetBytes($json)

    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.ContentEncoding = Get-Utf8NoBomEncoding
    $Response.ContentLength64 = $buffer.Length
    $Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Response.OutputStream.Close()
}

function Try-WriteJsonResponse {
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory)]
        [int]$StatusCode,
        [Parameter(Mandatory)]
        [object]$Body
    )

    try {
        Write-JsonResponse -Response $Response -StatusCode $StatusCode -Body $Body
        return $true
    }
    catch {
        try {
            $Response.Abort()
        }
        catch {
        }

        return $false
    }
}

function Get-RequestBodyText {
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerRequest]$Request
    )

    $reader = [System.IO.StreamReader]::new($Request.InputStream, $Request.ContentEncoding)
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }
}

function Test-IsAllowedUser {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [AllowNull()]
        [string]$UserId
    )

    $allowedUsers = @($Config.security.allowedUserIds)
    if ($allowedUsers.Count -eq 0) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($UserId)) {
        return $false
    }

    return $allowedUsers -contains $UserId
}

function Test-GuiIntent {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $patterns = @(
        '(^|\s)/gui(\s|$)',
        '点击',
        '点开',
        '打开',
        '启动',
        '打开窗口',
        '切换窗口',
        '看屏幕',
        '截图',
        '浏览器',
        '桌面',
        '应用',
        '软件',
        'teams',
        'microsoft teams',
        '发送消息',
        '发消息',
        '发送给',
        '回复给',
        'computer use',
        'computer-use',
        'gui'
    )

    foreach ($pattern in $patterns) {
        if ($Text -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-TeamsDeliveryTarget {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $sendToMatch = [regex]::Match(
        $Text,
        '发给\s*(.+?)(?:\s+(复制文本内容就行|复制文本就行|复制内容就行|复制就行|就行)\s*)?$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($sendToMatch.Success) {
        return [PSCustomObject]@{
            contact = $sendToMatch.Groups[1].Value.Trim()
        }
    }

    $chineseMatch = [regex]::Match(
        $Text,
        '给\s*(.+?)\s*发送\s*(.+)$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($chineseMatch.Success) {
        return [PSCustomObject]@{
            contact = $chineseMatch.Groups[1].Value.Trim()
        }
    }

    $englishMatch = [regex]::Match(
        $Text,
        'send\s+.+?\s+to\s+(.+)$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($englishMatch.Success) {
        return [PSCustomObject]@{
            contact = $englishMatch.Groups[1].Value.Trim()
        }
    }

    return $null
}

function Get-PayloadMediaItems {
    param(
        [Parameter(Mandatory)]
        [object]$Payload
    )

    if ($Payload.PSObject.Properties.Match('media').Count -eq 0) {
        return @()
    }

    return @($Payload.media)
}

function Get-LatestMediaCacheKey {
    param(
        [Parameter(Mandatory)]
        [object]$Payload
    )

    $sessionId = [string](Get-OptionalPropertyValue -InputObject $Payload -Name 'sessionId' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($sessionId)) {
        return 'session:' + $sessionId.Trim()
    }

    $userId = [string](Get-OptionalPropertyValue -InputObject $Payload -Name 'userId' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($userId)) {
        return 'user:' + $userId.Trim()
    }

    return ''
}

function Set-LatestMediaForPayload {
    param(
        [Parameter(Mandatory)]
        [object]$Payload,
        [Parameter(Mandatory)]
        [object[]]$MediaItems,
        [Parameter(Mandatory)]
        [object]$RuntimeState
    )

    if ($MediaItems.Count -eq 0) {
        return
    }

    $cacheKey = Get-LatestMediaCacheKey -Payload $Payload
    if ([string]::IsNullOrWhiteSpace($cacheKey)) {
        return
    }

    $nextEntries = @()
    foreach ($entry in @($RuntimeState.mediaEntries)) {
        if ($null -eq $entry) {
            continue
        }

        $entryCacheKey = [string](Get-OptionalPropertyValue -InputObject $entry -Name 'cacheKey' -DefaultValue '')
        if ($entryCacheKey -eq $cacheKey) {
            continue
        }

        $nextEntries += $entry
    }

    $RuntimeState.mediaEntries = @([PSCustomObject]@{
        cacheKey = $cacheKey
        timestamp = (Get-Date).ToString('o')
        media = @($MediaItems)
    }) + @($nextEntries)
}

function Get-LatestMediaForPayload {
    param(
        [Parameter(Mandatory)]
        [object]$Payload,
        [Parameter(Mandatory)]
        [object]$RuntimeState
    )

    $cacheKey = Get-LatestMediaCacheKey -Payload $Payload
    if ([string]::IsNullOrWhiteSpace($cacheKey)) {
        return @()
    }

    foreach ($entry in @($RuntimeState.mediaEntries)) {
        if ($null -eq $entry) {
            continue
        }

        $entryCacheKey = [string](Get-OptionalPropertyValue -InputObject $entry -Name 'cacheKey' -DefaultValue '')
        if ($entryCacheKey -ne $cacheKey) {
            continue
        }

        return @((Get-OptionalPropertyValue -InputObject $entry -Name 'media' -DefaultValue @()))
    }

    return @()
}

function Set-BridgeSessionActivity {
    param(
        [Parameter(Mandatory)]
        [object]$Payload,
        [Parameter(Mandatory)]
        [object]$Result,
        [Parameter(Mandatory)]
        [object]$RuntimeState
    )

    $sessionId = [string](Get-OptionalPropertyValue -InputObject $Payload -Name 'sessionId' -DefaultValue '')
    $userId = [string](Get-OptionalPropertyValue -InputObject $Payload -Name 'userId' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($sessionId) -and [string]::IsNullOrWhiteSpace($userId)) {
        return
    }

    $sessionKey = if (-not [string]::IsNullOrWhiteSpace($sessionId)) {
        'session:' + $sessionId.Trim()
    }
    else {
        'user:' + $userId.Trim()
    }

    $nextSessions = @()
    foreach ($entry in @($RuntimeState.sessions)) {
        if ($null -eq $entry) {
            continue
        }

        $entrySessionKey = [string](Get-OptionalPropertyValue -InputObject $entry -Name 'sessionKey' -DefaultValue '')
        if ($entrySessionKey -eq $sessionKey) {
            continue
        }

        $nextSessions += $entry
    }

    $text = [string](Get-OptionalPropertyValue -InputObject $Payload -Name 'text' -DefaultValue '')
    $mediaItems = @(Get-PayloadMediaItems -Payload $Payload)
    $lastTextPreview = ''
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        if ($text.Length -le 120) {
            $lastTextPreview = $text
        }
        else {
            $lastTextPreview = $text.Substring(0, 120)
        }
    }

    $RuntimeState.sessions = @([PSCustomObject]@{
        sessionKey = $sessionKey
        sessionId = $sessionId
        userId = $userId
        route = [string](Get-OptionalPropertyValue -InputObject $Result -Name 'route' -DefaultValue '')
        mode = [string](Get-OptionalPropertyValue -InputObject $Result -Name 'mode' -DefaultValue '')
        hasMedia = ($mediaItems.Count -gt 0)
        lastTextPreview = $lastTextPreview
        lastActivityAt = (Get-Date).ToString('o')
    }) + @($nextSessions)
}

function Get-TeamsMediaDeliveryRequest {
    param(
        [Parameter(Mandatory)]
        [object]$Payload,
        [Parameter(Mandatory)]
        [object]$RuntimeState
    )

    $text = [string](Get-OptionalPropertyValue -InputObject $Payload -Name 'text' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($text) -or $text -notmatch 'teams|microsoft teams') {
        return $null
    }

    $target = Get-TeamsDeliveryTarget -Text $text
    if ($null -eq $target -or [string]::IsNullOrWhiteSpace([string]$target.contact)) {
        return $null
    }

    $mediaItems = @(Get-PayloadMediaItems -Payload $Payload)
    if ($mediaItems.Count -eq 0) {
        $mediaItems = @(Get-LatestMediaForPayload -Payload $Payload -RuntimeState $RuntimeState)
    }

    foreach ($item in $mediaItems) {
        $kind = [string](Get-OptionalPropertyValue -InputObject $item -Name 'kind' -DefaultValue '')
        $path = [string](Get-OptionalPropertyValue -InputObject $item -Name 'path' -DefaultValue '')
        if ($kind -ne 'image' -or [string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        return [PSCustomObject]@{
            contact = [string]$target.contact
            imagePath = $path
        }
    }

    return $null
}

function Test-TeamsImageOnlySendRequest {
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    if ($Text -notmatch 'teams|microsoft teams') {
        return $false
    }

    return (
        [regex]::IsMatch($Text, '给\s*.+?\s*发送\s*$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) -or
        [regex]::IsMatch($Text, '发给\s*.+?\s*$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    )
}

function Get-GitHubTeamsDeliveryRequest {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    if ($Text -notmatch 'github' -or $Text -notmatch 'teams|microsoft teams') {
        return $null
    }

    $target = Get-TeamsDeliveryTarget -Text $Text
    if ($null -eq $target -or [string]::IsNullOrWhiteSpace([string]$target.contact)) {
        return $null
    }

    $lookupText = $Text
    $lookupText = [regex]::Replace($lookupText, '\s*在?\s*teams\s*发给\s*.+$', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $lookupText = [regex]::Replace($lookupText, '\s*打开\s*(?:我的)?\s*teams\s*给\s*.+$', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $lookupText = [regex]::Replace($lookupText, '\s*在?\s*teams\s*给\s*.+?\s*发送\s*.+$', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $lookupText = [regex]::Replace($lookupText, '\s*(复制文本内容就行|复制文本就行|复制内容就行|复制就行|就行)\s*$', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $lookupText = $lookupText.Trim()

    if ([string]::IsNullOrWhiteSpace($lookupText) -or $lookupText -eq $Text.Trim()) {
        return $null
    }

    return [PSCustomObject]@{
        contact = [string]$target.contact
        lookupText = $lookupText
    }
}

function New-DeliveryLookupPrompt {
    param(
        [Parameter(Mandatory)]
        [string]$LookupText,
        [Parameter(Mandatory)]
        [string]$RepoPath
    )

    return (@(
        'You are preparing the exact message body that will be sent to Microsoft Teams.',
        "Repository path: $RepoPath",
        'Search normally, but return only the final message text to send.',
        'Do not include markdown headings, bullets, code fences, or explanations.',
        'If the user asks for a GitHub code link, return one concise Chinese sentence that includes a short description and the single best URL.',
        'Prefer the format `这是 DataGrid.cs 的 GitHub 代码链接： https://...` on one line.',
        '',
        'User request:',
        $LookupText
    ) -join [Environment]::NewLine)
}

function Get-FirstUrlFromText {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $match = [regex]::Match($Text, 'https?://\S+', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        return ''
    }

    return $match.Value.TrimEnd('.', ',', ';', ':', ')', ']', '}', '"', "'")
}

function Get-DeliveryLabel {
    param(
        [Parameter(Mandatory)]
        [string]$LookupText,
        [Parameter(Mandatory)]
        [string]$Url
    )

    $fileNameMatch = [regex]::Match($LookupText, '([A-Za-z0-9_.-]+\.[A-Za-z0-9]+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($fileNameMatch.Success) {
        return $fileNameMatch.Groups[1].Value
    }

    try {
        $uri = [System.Uri]$Url
        $segments = @($uri.Segments)
        if ($segments.Count -gt 0) {
            $lastSegment = [System.Uri]::UnescapeDataString($segments[$segments.Count - 1]).Trim('/')
            if (-not [string]::IsNullOrWhiteSpace($lastSegment)) {
                return $lastSegment
            }
        }
    }
    catch {
    }

    return ''
}

function Format-TeamsDeliveryBody {
    param(
        [Parameter(Mandatory)]
        [string]$LookupText,
        [Parameter(Mandatory)]
        [string]$LookupOutput
    )

    $normalizedOutput = ($LookupOutput -replace '\r?\n+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedOutput)) {
        return ''
    }

    $url = Get-FirstUrlFromText -Text $normalizedOutput
    if ([string]::IsNullOrWhiteSpace($url)) {
        return $normalizedOutput
    }

    $label = Get-DeliveryLabel -LookupText $LookupText -Url $url
    if ([string]::IsNullOrWhiteSpace($label)) {
        return "这是找到的 GitHub 代码链接： $url"
    }

    return "这是 $label 的 GitHub 代码链接： $url"
}

function Get-ExecutionMode {
    param(
        [Parameter(Mandatory)]
        [object]$Payload
    )

    $text = [string]$Payload.text
    $mode = [string]$Payload.mode

    if ($text -match '(^|\s)/apply(\s|$)') {
        return 'apply'
    }

    if ([string]::IsNullOrWhiteSpace($mode)) {
        return 'read'
    }

    if ($mode -notin @('read', 'apply')) {
        return 'read'
    }

    return $mode
}

function New-CopilotPrompt {
    param(
        [Parameter(Mandatory)]
        [string]$UserText,
        [Parameter(Mandatory)]
        [string]$RepoPath,
        [Parameter(Mandatory)]
        [ValidateSet('read', 'apply')]
        [string]$Mode,
        [AllowNull()]
        [string]$SessionId
    )

    $modeInstructions = if ($Mode -eq 'apply') {
        @(
            '- You may modify files under the repository path when needed.',
            '- Never run git push, never modify files outside the repository, and avoid destructive system changes.',
            '- Keep changes minimal and summarize changed files explicitly.'
        )
    }
    else {
        @(
            '- Read-only mode: do not modify files, do not create files, and do not run destructive commands.',
            '- You may search, read, analyze, and suggest next actions only.',
            '- If the user clearly needs file changes, explain that /apply mode is required.'
        )
    }

    $sessionLine = if ([string]::IsNullOrWhiteSpace($SessionId)) {
        '- Session: none'
    }
    else {
        "- Session: $SessionId"
    }

    $instructions = @(
        'You are running inside a local bridge for a single repository.',
        "- Repository path: $RepoPath",
        $sessionLine,
        '- Prefer concise Chinese output.',
        '- Stay within the repository path unless absolutely necessary.',
        '- Never run git push, never exfiltrate secrets, and never use unrelated directories.'
    ) + $modeInstructions

    return (@(
        ($instructions -join [Environment]::NewLine),
        '',
        'Reply using this structure:',
        '1. Outcome',
        '2. Files changed',
        '3. Next step',
        '',
        'User request:',
        $UserText
    ) -join [Environment]::NewLine)
}

function Invoke-ExternalRunner {
    param(
        [Parameter(Mandatory)]
        [string]$Command,
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [Parameter(Mandatory)]
        [string]$WorkingDirectory,
        [ValidateRange(1, 3600)]
        [int]$TimeoutSeconds = 120
    )

        $exitCode = $null
    $utf8Encoding = Get-Utf8NoBomEncoding
    $resolvedCommand = Resolve-CommandPath -Command $Command
    $process = [System.Diagnostics.Process]::new()
    try {
        $process.StartInfo = [System.Diagnostics.ProcessStartInfo]::new()

        $resolvedArguments = @($Arguments)
        if ($resolvedCommand.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
            $shellCommand = 'pwsh'
            try {
                $process.StartInfo.FileName = Resolve-CommandPath -Command $shellCommand
            }
            catch {
                $shellCommand = 'powershell'
                $process.StartInfo.FileName = Resolve-CommandPath -Command $shellCommand
            }

            $resolvedArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $resolvedCommand) + $resolvedArguments
        }
        else {
            $process.StartInfo.FileName = $resolvedCommand
        }

        foreach ($argument in $resolvedArguments) {
            [void]$process.StartInfo.ArgumentList.Add($argument)
        }

        $process.StartInfo.WorkingDirectory = $WorkingDirectory
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        $process.StartInfo.StandardOutputEncoding = $utf8Encoding
        $process.StartInfo.StandardErrorEncoding = $utf8Encoding

        [void]$process.Start()

        $completed = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $completed) {
            try {
                $process.Kill($true)
            }
            catch {
            }

            return [PSCustomObject]@{
                output = "Runner timed out after $TimeoutSeconds seconds."
                exitCode = 124
                timedOut = $true
            }
        }

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode

        $combinedOutput = @($stdout.Trim(), $stderr.Trim()) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }
    finally {
        $process.Dispose()
    }

    return [PSCustomObject]@{
        output = ($combinedOutput -join [Environment]::NewLine).Trim()
        exitCode = $exitCode
        timedOut = $false
    }
}

function Invoke-CopilotRequest {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [string]$Prompt,
        [AllowNull()]
        [string]$SessionName
    )

    $arguments = @(
        '-p', $Prompt,
        '-s',
        '--allow-all-tools',
        '--output-format', 'text',
        '--no-color',
        '--no-ask-user',
        '--add-dir', $Config.repo.path,
        '--deny-tool=shell(git push)'
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$Config.copilot.model)) {
        $arguments += @('--model', [string]$Config.copilot.model)
    }

    if (-not [string]::IsNullOrWhiteSpace($SessionName)) {
        $arguments += @('--name', $SessionName)
    }

    return Invoke-ExternalRunner -Command ([string]$Config.copilot.command) -Arguments $arguments -WorkingDirectory ([string]$Config.repo.path)
}

function Invoke-GitHubTeamsDelivery {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [object]$Payload
    )

    $request = Get-GitHubTeamsDeliveryRequest -Text ([string]$Payload.text)
    if ($null -eq $request) {
        return $null
    }

    $sessionId = [string]$Payload.sessionId
    $lookupSessionId = if ([string]::IsNullOrWhiteSpace($sessionId)) {
        'teams-delivery-lookup'
    }
    else {
        "$sessionId-lookup"
    }

    $lookupPrompt = New-DeliveryLookupPrompt -LookupText ([string]$request.lookupText) -RepoPath ([string]$Config.repo.path)
    $lookupStartedAt = Get-Date
    $lookupResult = Invoke-CopilotRequest -Config $Config -Prompt $lookupPrompt -SessionName $lookupSessionId
    $lookupDurationMs = [int]((Get-Date) - $lookupStartedAt).TotalMilliseconds
    $deliveryBody = Format-TeamsDeliveryBody -LookupText ([string]$request.lookupText) -LookupOutput ([string]$lookupResult.output)

    if ($lookupResult.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($deliveryBody)) {
        return [PSCustomObject]@{
            ok = $false
            route = 'copilot'
            mode = (Get-ExecutionMode -Payload $Payload)
            sessionId = $sessionId
            userId = [string]$Payload.userId
            reply = $lookupResult.output
            exitCode = $lookupResult.exitCode
            durationMs = $lookupDurationMs
            repoPath = [string]$Config.repo.path
        }
    }

    $guiPrompt = "打开我的teams 给$([string]$request.contact) 发送 $deliveryBody"
    $guiStartedAt = Get-Date
    $guiResult = Invoke-GuiRunner -Config $Config -Prompt $guiPrompt
    $guiDurationMs = [int]((Get-Date) - $guiStartedAt).TotalMilliseconds

    return [PSCustomObject]@{
        ok = ($guiResult.exitCode -eq 0)
        route = 'gui'
        mode = (Get-ExecutionMode -Payload $Payload)
        sessionId = $sessionId
        userId = [string]$Payload.userId
        reply = $guiResult.output
        exitCode = $guiResult.exitCode
        durationMs = ($lookupDurationMs + $guiDurationMs)
        guiConfigured = [bool]$guiResult.configured
        timedOut = [bool](Get-OptionalPropertyValue -InputObject $guiResult -Name 'timedOut' -DefaultValue $false)
    }
}

function Invoke-TeamsMediaDelivery {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [object]$Payload,
        [Parameter(Mandatory)]
        [object]$RuntimeState
    )

    $request = Get-TeamsMediaDeliveryRequest -Payload $Payload -RuntimeState $RuntimeState
    if ($null -eq $request) {
        return $null
    }

    $guiPrompt = "打开我的teams 给$([string]$request.contact)发送 [[MEDIA_PATH:$([string]$request.imagePath)]]"
    $guiStartedAt = Get-Date
    $guiResult = Invoke-GuiRunner -Config $Config -Prompt $guiPrompt
    $guiDurationMs = [int]((Get-Date) - $guiStartedAt).TotalMilliseconds

    return [PSCustomObject]@{
        ok = ($guiResult.exitCode -eq 0)
        route = 'gui-media'
        mode = (Get-ExecutionMode -Payload $Payload)
        sessionId = [string]$Payload.sessionId
        userId = [string]$Payload.userId
        reply = $guiResult.output
        exitCode = $guiResult.exitCode
        durationMs = $guiDurationMs
        guiConfigured = [bool]$guiResult.configured
        timedOut = [bool](Get-OptionalPropertyValue -InputObject $guiResult -Name 'timedOut' -DefaultValue $false)
    }
}

function Invoke-GuiRunner {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    if ($null -eq $Config.computerUse -or [string]::IsNullOrWhiteSpace([string]$Config.computerUse.command)) {
        return [PSCustomObject]@{
            configured = $false
            output = 'GUI route requested, but no local GitHub CLI computer-use runner is configured yet.'
            exitCode = 0
        }
    }

    $runnerPath = Join-Path $PSScriptRoot 'Start-GitHubCliComputerUseRunner.py'
    $arguments = @()
    foreach ($argument in @($Config.computerUse.arguments)) {
        $arguments += ([string]$argument).Replace('{PROMPT}', $Prompt).Replace('{REPO}', [string]$Config.repo.path).Replace('{RUNNER_PATH}', $runnerPath)
    }

    $timeoutSeconds = [int](Get-OptionalPropertyValue -InputObject $Config.computerUse -Name 'timeoutSeconds' -DefaultValue 180)
    $result = Invoke-ExternalRunner -Command ([string]$Config.computerUse.command) -Arguments $arguments -WorkingDirectory ([string]$Config.repo.path) -TimeoutSeconds $timeoutSeconds

    $output = if ($result.timedOut) {
        $details = if ([string]::IsNullOrWhiteSpace($result.output)) {
            'Local GitHub CLI computer-use runner exceeded the configured timeout.'
        }
        else {
            $result.output
        }

        "GUI route timed out.`r`n`r`nDetails: $details"
    }
    else {
        $result.output
    }

    return [PSCustomObject]@{
        configured = $true
        output = $output
        exitCode = $result.exitCode
        timedOut = [bool]$result.timedOut
    }
}

function Write-BridgeLog {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [object]$Entry
    )

    $logDirectory = [string]$Config.logging.directory
    if ([string]::IsNullOrWhiteSpace($logDirectory)) {
        return
    }

    if (-not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }

    $logPath = Join-Path $logDirectory 'bridge-log.jsonl'
    $line = (ConvertTo-BridgeJson -InputObject $Entry)
    [System.IO.File]::AppendAllText($logPath, $line + [Environment]::NewLine, (Get-Utf8NoBomEncoding))
}

function Invoke-BridgeMessage {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [object]$Payload,
        [Parameter(Mandatory)]
        [object]$RuntimeState
    )

    $text = [string]$Payload.text
    $mediaItems = @(Get-PayloadMediaItems -Payload $Payload)
    if ([string]::IsNullOrWhiteSpace($text) -and $mediaItems.Count -eq 0) {
        throw 'Payload field text or media is required.'
    }

    if ($mediaItems.Count -gt 0) {
        Set-LatestMediaForPayload -Payload $Payload -MediaItems $mediaItems -RuntimeState $RuntimeState
    }

    Invoke-BridgeRuntimeMaintenance -Config $Config -RuntimeState $RuntimeState

    $mode = Get-ExecutionMode -Payload $Payload
    $requestedRoute = if ($Payload.PSObject.Properties.Match('route').Count -gt 0) {
        [string]$Payload.route
    }
    else {
        ''
    }
    $route = if ($requestedRoute -eq 'gui' -or (Test-GuiIntent -Text $text)) { 'gui' } else { 'copilot' }
    $sessionId = [string]$Payload.sessionId
    $userId = [string]$Payload.userId
    $startedAt = Get-Date

    $mediaDeliveryResult = Invoke-TeamsMediaDelivery -Config $Config -Payload $Payload -RuntimeState $RuntimeState
    if ($null -ne $mediaDeliveryResult) {
        Set-BridgeSessionActivity -Payload $Payload -Result $mediaDeliveryResult -RuntimeState $RuntimeState
        return $mediaDeliveryResult
    }

    if ((Test-TeamsImageOnlySendRequest -Text $text) -and $mediaItems.Count -eq 0) {
        $result = [PSCustomObject]@{
            ok = $false
            route = 'gui-media-missing'
            mode = $mode
            sessionId = $sessionId
            userId = $userId
            reply = $script:MissingTeamsImageReply
            exitCode = 1
            durationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds
        }
        Set-BridgeSessionActivity -Payload $Payload -Result $result -RuntimeState $RuntimeState
        return $result
    }

    if ([string]::IsNullOrWhiteSpace($text) -and $mediaItems.Count -gt 0) {
        $result = [PSCustomObject]@{
            ok = $true
            route = 'media-cache'
            mode = $mode
            sessionId = $sessionId
            userId = $userId
            reply = '图片已收到并缓存。要发到 Teams，请再发：打开我的teams 给某人发送'
            exitCode = 0
            durationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds
        }
        Set-BridgeSessionActivity -Payload $Payload -Result $result -RuntimeState $RuntimeState
        return $result
    }

    $deliveryResult = Invoke-GitHubTeamsDelivery -Config $Config -Payload $Payload
    if ($null -ne $deliveryResult) {
        Set-BridgeSessionActivity -Payload $Payload -Result $deliveryResult -RuntimeState $RuntimeState
        return $deliveryResult
    }

    if ($route -eq 'gui') {
        $guiResult = Invoke-GuiRunner -Config $Config -Prompt $text
        $durationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds

        $result = [PSCustomObject]@{
            ok = ($guiResult.exitCode -eq 0)
            route = 'gui'
            mode = $mode
            sessionId = $sessionId
            userId = $userId
            reply = $guiResult.output
            exitCode = $guiResult.exitCode
            durationMs = $durationMs
            guiConfigured = [bool]$guiResult.configured
            timedOut = [bool](Get-OptionalPropertyValue -InputObject $guiResult -Name 'timedOut' -DefaultValue $false)
        }
        Set-BridgeSessionActivity -Payload $Payload -Result $result -RuntimeState $RuntimeState
        return $result
    }

    $prompt = New-CopilotPrompt -UserText $text -RepoPath ([string]$Config.repo.path) -Mode $mode -SessionId $sessionId
    $copilotResult = Invoke-CopilotRequest -Config $Config -Prompt $prompt -SessionName $sessionId
    $durationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds

    $result = [PSCustomObject]@{
        ok = ($copilotResult.exitCode -eq 0)
        route = 'copilot'
        mode = $mode
        sessionId = $sessionId
        userId = $userId
        reply = $copilotResult.output
        exitCode = $copilotResult.exitCode
        durationMs = $durationMs
        repoPath = [string]$Config.repo.path
    }

    Set-BridgeSessionActivity -Payload $Payload -Result $result -RuntimeState $RuntimeState
    return $result
}

function Handle-BridgeRequest {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [object]$RuntimeState,
        [Parameter(Mandatory)]
        [System.Net.HttpListenerContext]$Context
    )

    $request = $Context.Request
    $response = $Context.Response

    try {
        Invoke-BridgeRuntimeMaintenance -Config $Config -RuntimeState $RuntimeState

        if ($request.HttpMethod -eq 'GET' -and $request.Url.AbsolutePath -eq '/health') {
            Write-JsonResponse -Response $response -StatusCode 200 -Body ([PSCustomObject]@{
                ok = $true
                status = 'healthy'
                repoPath = [string]$Config.repo.path
                prefix = [string]$Config.server.prefix
                copilotCommand = [string]$Config.copilot.command
                runtimeStatePath = [string]$Config.storage.runtimeStatePath
                sessionCount = @($RuntimeState.sessions).Count
                mediaEntryCount = @($RuntimeState.mediaEntries).Count
                guiConfigured = -not [string]::IsNullOrWhiteSpace([string](Get-OptionalPropertyValue -InputObject $Config.computerUse -Name 'command' -DefaultValue ''))
            })
            return
        }

        if ($request.HttpMethod -ne 'POST' -or $request.Url.AbsolutePath -ne '/message') {
            Write-JsonResponse -Response $response -StatusCode 404 -Body ([PSCustomObject]@{
                ok = $false
                error = 'Endpoint not found.'
            })
            return
        }

        $bodyText = Get-RequestBodyText -Request $request
        $payload = $bodyText | ConvertFrom-Json

        if (-not (Test-IsAllowedUser -Config $Config -UserId ([string]$payload.userId))) {
            Write-JsonResponse -Response $response -StatusCode 403 -Body ([PSCustomObject]@{
                ok = $false
                error = 'User is not allowed.'
            })
            return
        }

        $result = Invoke-BridgeMessage -Config $Config -Payload $payload -RuntimeState $RuntimeState
        Save-BridgeRuntimeState -Path ([string]$Config.storage.runtimeStatePath) -RuntimeState $RuntimeState
        Write-BridgeLog -Config $Config -Entry ([PSCustomObject]@{
            timestamp = (Get-Date).ToString('o')
            request = $payload
            response = $result
        })

        Write-JsonResponse -Response $response -StatusCode 200 -Body $result
    }
    catch {
        $null = Try-WriteJsonResponse -Response $response -StatusCode 500 -Body ([PSCustomObject]@{
            ok = $false
            error = $_.Exception.Message
        })
    }
}

function Main {
    $config = Get-BridgeConfig -Path $ConfigPath
    $runtimeState = Get-BridgeRuntimeState -Path ([string]$config.storage.runtimeStatePath)
    Invoke-BridgeRuntimeMaintenance -Config $config -RuntimeState $runtimeState
    Save-BridgeRuntimeState -Path ([string]$config.storage.runtimeStatePath) -RuntimeState $runtimeState
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add([string]$config.server.prefix)
    $listener.Start()

    Write-Host "Copilot WeChat bridge listening on $($config.server.prefix)"
    Write-Host "Repo path: $($config.repo.path)"
    Write-Host "Runtime state: $($config.storage.runtimeStatePath)"

    $processedRequests = 0

    try {
        while ($listener.IsListening) {
            if ($MaxRequests -gt 0 -and $processedRequests -ge $MaxRequests) {
                break
            }

            $context = $listener.GetContext()
            Handle-BridgeRequest -Config $config -RuntimeState $runtimeState -Context $context
            $processedRequests++
        }
    }
    finally {
        $listener.Stop()
        $listener.Close()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}