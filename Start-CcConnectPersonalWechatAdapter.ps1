#!/usr/bin/env pwsh
<#!
.SYNOPSIS
Starts a minimal personal WeChat adapter for the local Copilot bridge.

.DESCRIPTION
Polls a cc-connect-style personal WeChat endpoint, forwards incoming text
messages to the local bridge, and optionally sends the bridge reply back to the
same chat. For local validation without real credentials, the adapter can read
mock updates from a JSON file and write outbound replies to a sink file. In
real mode it speaks the ilink HTTP API used by cc-connect: POST getupdates with
Bearer auth, sync buffer persistence, and sendmessage using context_token.

.PARAMETER ConfigPath
Path to the adapter configuration JSON file.

.PARAMETER RunOnce
Processes at most one polling cycle and exits.

.PARAMETER MaxPolls
Maximum polling cycles before exit. Use 0 for unlimited.

.EXAMPLE
./Start-CcConnectPersonalWechatAdapter.ps1 -ConfigPath ./adapter.sample.json -RunOnce
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'adapter.json'),
    [switch]$RunOnce,
    [ValidateRange(0, 1000000)]
    [int]$MaxPolls = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MillisecondsPerSecond = 1000
$script:DefaultIlinkPostTimeoutSec = 30
$script:DefaultPollTimeoutSec = 20
$script:PollTimeoutBufferSec = 5
$script:InboundImageDownloadTimeoutSec = 90

function New-DefaultAdapterState {
    return [PSCustomObject]@{
        lastUpdateId = 0
        syncBuf = ''
        botId = ''
        latestMediaEntries = @()
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

function Set-OptionalPropertyValue {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,
        [Parameter(Mandatory)]
        [string]$Name,
        $Value
    )

    if ($InputObject.PSObject.Properties.Match($Name).Count -gt 0) {
        $InputObject.$Name = $Value
        return
    }

    $InputObject | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
}

function ConvertTo-AdapterJson {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject
    )

    return $InputObject | ConvertTo-Json -Depth 10
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (Get-Utf8NoBomEncoding))
}

function Append-Utf8File {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Content
    )

    [System.IO.File]::AppendAllText($Path, $Content, (Get-Utf8NoBomEncoding))
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,
        [Parameter(Mandatory)]
        [string]$Name,
        $DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    if ($InputObject.PSObject.Properties.Match($Name).Count -gt 0) {
        return $InputObject.$Name
    }

    return $DefaultValue
}

function New-RandomHex {
    param(
        [ValidateRange(1, 1024)]
        [int]$ByteCount = 8
    )

    $bytes = New-Object byte[] $ByteCount
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return ([System.BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
}

function New-RandomWechatUin {
    $bytes = New-Object byte[] 4
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $value = [uint32]$bytes[0] -shl 24
    $value = $value -bor ([uint32]$bytes[1] -shl 16)
    $value = $value -bor ([uint32]$bytes[2] -shl 8)
    $value = $value -bor [uint32]$bytes[3]
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$value))
}

function Get-BodyFromItemList {
    param(
        [Parameter(Mandatory)]
        [object[]]$Items
    )

    if ($Items.Count -eq 0) {
        return ''
    }

    foreach ($item in $Items) {
        $itemType = [int](Get-OptionalPropertyValue -InputObject $item -Name 'type' -DefaultValue 0)
        switch ($itemType) {
            1 {
                $textItem = Get-OptionalPropertyValue -InputObject $item -Name 'text_item'
                if ($null -eq $textItem) {
                    continue
                }

                $text = [string](Get-OptionalPropertyValue -InputObject $textItem -Name 'text' -DefaultValue '')
                $text = $text.Trim()
                if ([string]::IsNullOrWhiteSpace($text)) {
                    continue
                }

                $ref = Get-OptionalPropertyValue -InputObject $item -Name 'ref_msg'
                if ($null -eq $ref) {
                    return $text
                }

                $parts = New-Object System.Collections.Generic.List[string]
                $refTitle = [string](Get-OptionalPropertyValue -InputObject $ref -Name 'title' -DefaultValue '')
                if (-not [string]::IsNullOrWhiteSpace($refTitle)) {
                    $parts.Add($refTitle)
                }

                $refMessageItem = Get-OptionalPropertyValue -InputObject $ref -Name 'message_item'
                if ($null -ne $refMessageItem) {
                    $refBody = Get-BodyFromItemList -Items @($refMessageItem)
                    if (-not [string]::IsNullOrWhiteSpace($refBody)) {
                        $parts.Add($refBody)
                    }
                }

                if ($parts.Count -eq 0) {
                    return $text
                }

                return ('[引用: ' + ($parts -join ' | ') + ']' + [Environment]::NewLine + $text)
            }
            3 {
                $voiceItem = Get-OptionalPropertyValue -InputObject $item -Name 'voice_item'
                if ($null -eq $voiceItem) {
                    continue
                }

                $voiceText = [string](Get-OptionalPropertyValue -InputObject $voiceItem -Name 'text' -DefaultValue '')
                if (-not [string]::IsNullOrWhiteSpace($voiceText)) {
                    return $voiceText.Trim()
                }
            }
        }
    }

    return ''
}

function Get-UpdateItemTypeNames {
    param(
        [Parameter(Mandatory)]
        [object]$Update
    )

    $typeNames = New-Object System.Collections.Generic.List[string]
    $itemList = @(Get-OptionalPropertyValue -InputObject $Update -Name 'item_list' -DefaultValue @())
    foreach ($item in $itemList) {
        $itemType = [int](Get-OptionalPropertyValue -InputObject $item -Name 'type' -DefaultValue 0)
        $typeName = switch ($itemType) {
            1 { 'text'; break }
            2 { 'image'; break }
            3 { 'voice'; break }
            4 { 'file'; break }
            5 { 'video'; break }
            default { 'unknown:' + $itemType; break }
        }

        $typeNames.Add($typeName)
    }

    return @($typeNames)
}

function Get-UpdateDiagnosticSummary {
    param(
        [Parameter(Mandatory)]
        [object]$Update
    )

    $itemTypeNames = @(Get-UpdateItemTypeNames -Update $Update)

    return [PSCustomObject]@{
        fromUserId = [string](Get-OptionalPropertyValue -InputObject $Update -Name 'from_user_id' -DefaultValue '')
        messageId = [long](Get-OptionalPropertyValue -InputObject $Update -Name 'message_id' -DefaultValue 0)
        seq = [long](Get-OptionalPropertyValue -InputObject $Update -Name 'seq' -DefaultValue 0)
        createTimeMs = [long](Get-OptionalPropertyValue -InputObject $Update -Name 'create_time_ms' -DefaultValue 0)
        messageType = [int](Get-OptionalPropertyValue -InputObject $Update -Name 'message_type' -DefaultValue 0)
        itemTypes = $itemTypeNames
        itemCount = $itemTypeNames.Count
        hasContextToken = (-not [string]::IsNullOrWhiteSpace([string](Get-OptionalPropertyValue -InputObject $Update -Name 'context_token' -DefaultValue '')))
        extractedText = Get-BodyFromItemList -Items @(Get-OptionalPropertyValue -InputObject $Update -Name 'item_list' -DefaultValue @())
    }
}

function Get-IlinkImageItem {
    param(
        [Parameter(Mandatory)]
        [object]$Update
    )

    $itemList = @(Get-OptionalPropertyValue -InputObject $Update -Name 'item_list' -DefaultValue @())
    foreach ($item in $itemList) {
        $itemType = [int](Get-OptionalPropertyValue -InputObject $item -Name 'type' -DefaultValue 0)
        if ($itemType -ne 2) {
            continue
        }

        return (Get-OptionalPropertyValue -InputObject $item -Name 'image_item')
    }

    return $null
}

function Get-IlinkImageDecryptMaterial {
    param(
        [Parameter(Mandatory)]
        [object]$ImageItem
    )

    $media = Get-OptionalPropertyValue -InputObject $ImageItem -Name 'media'
    if ($null -eq $media) {
        return $null
    }

    $encryptQueryParam = [string](Get-OptionalPropertyValue -InputObject $media -Name 'encrypt_query_param' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($encryptQueryParam)) {
        return $null
    }

    $aesKeyHex = [string](Get-OptionalPropertyValue -InputObject $ImageItem -Name 'aeskey' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($aesKeyHex)) {
        try {
            $rawKey = [System.Convert]::FromHexString($aesKeyHex.Trim())
            if ($rawKey.Length -eq 16) {
                return [PSCustomObject]@{
                    encryptQueryParam = $encryptQueryParam
                    aesKeyBase64 = [Convert]::ToBase64String($rawKey)
                    hasKey = $true
                    keySource = 'image_item.aeskey'
                }
            }
        }
        catch {
        }
    }

    $aesKeyBase64 = [string](Get-OptionalPropertyValue -InputObject $media -Name 'aes_key' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($aesKeyBase64)) {
        return [PSCustomObject]@{
            encryptQueryParam = $encryptQueryParam
            aesKeyBase64 = $aesKeyBase64.Trim()
            hasKey = $true
            keySource = 'image_item.media.aes_key'
        }
    }

    return [PSCustomObject]@{
        encryptQueryParam = $encryptQueryParam
        aesKeyBase64 = ''
        hasKey = $false
        keySource = ''
    }
}

function ConvertFrom-IlinkAesKey {
    param(
        [Parameter(Mandatory)]
        [string]$AesKeyBase64,
        [Parameter(Mandatory)]
        [string]$Label
    )

    $decoded = [Convert]::FromBase64String($AesKeyBase64.Trim())
    if ($decoded.Length -eq 16) {
        return $decoded
    }

    if ($decoded.Length -eq 32) {
        $hexText = [System.Text.Encoding]::UTF8.GetString($decoded)
        if ($hexText -match '^[0-9a-fA-F]{32}$') {
            return [System.Convert]::FromHexString($hexText)
        }
    }

    throw "${Label}: aes_key must decode to 16 raw bytes or 32-char hex text; got $($decoded.Length) bytes"
}

function Remove-Pkcs7Padding {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes,
        [int]$BlockSize = 16
    )

    if ($Bytes.Length -eq 0 -or ($Bytes.Length % $BlockSize) -ne 0) {
        throw "Invalid PKCS7 ciphertext length: $($Bytes.Length)"
    }

    $padLength = [int]$Bytes[$Bytes.Length - 1]
    if ($padLength -lt 1 -or $padLength -gt $BlockSize) {
        throw "Invalid PKCS7 padding length: $padLength"
    }

    for ($i = $Bytes.Length - $padLength; $i -lt $Bytes.Length; $i++) {
        if ([int]$Bytes[$i] -ne $padLength) {
            throw 'Invalid PKCS7 padding bytes.'
        }
    }

    $plain = New-Object byte[] ($Bytes.Length - $padLength)
    [Array]::Copy($Bytes, 0, $plain, 0, $plain.Length)
    return $plain
}

function ConvertFrom-AesEcbCiphertext {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Ciphertext,
        [Parameter(Mandatory)]
        [byte[]]$Key
    )

    if ($Key.Length -ne 16) {
        throw "AES key must be 16 bytes, got $($Key.Length)"
    }
    if (($Ciphertext.Length % 16) -ne 0) {
        throw "Ciphertext length $($Ciphertext.Length) is not block aligned."
    }

    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Mode = [System.Security.Cryptography.CipherMode]::ECB
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::None
        $aes.Key = $Key

        $decryptor = $aes.CreateDecryptor()
        try {
            $decrypted = $decryptor.TransformFinalBlock($Ciphertext, 0, $Ciphertext.Length)
        }
        finally {
            $decryptor.Dispose()
        }
    }
    finally {
        $aes.Dispose()
    }

    return Remove-Pkcs7Padding -Bytes $decrypted -BlockSize 16
}

function Get-IlinkImageMimeType {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xD8 -and $Bytes[2] -eq 0xFF) {
        return 'image/jpeg'
    }
    if ($Bytes.Length -ge 8 -and [System.Text.Encoding]::ASCII.GetString($Bytes, 0, 8) -eq "`x89PNG`r`n`x1a`n") {
        return 'image/png'
    }
    if ($Bytes.Length -ge 6) {
        $gifHeader = [System.Text.Encoding]::ASCII.GetString($Bytes, 0, 6)
        if ($gifHeader -eq 'GIF87a' -or $gifHeader -eq 'GIF89a') {
            return 'image/gif'
        }
    }
    if ($Bytes.Length -ge 12) {
        $riff = [System.Text.Encoding]::ASCII.GetString($Bytes, 0, 4)
        $webp = [System.Text.Encoding]::ASCII.GetString($Bytes, 8, 4)
        if ($riff -eq 'RIFF' -and $webp -eq 'WEBP') {
            return 'image/webp'
        }
    }

    return 'image/jpeg'
}

function Get-IlinkImageExtension {
    param(
        [Parameter(Mandatory)]
        [string]$MimeType
    )

    switch ($MimeType) {
        'image/png' { return '.png' }
        'image/gif' { return '.gif' }
        'image/webp' { return '.webp' }
        default { return '.jpg' }
    }
}

function Save-IlinkInboundImage {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [object]$Update
    )

    $imageItem = Get-IlinkImageItem -Update $Update
    if ($null -eq $imageItem) {
        return $null
    }

    $material = Get-IlinkImageDecryptMaterial -ImageItem $imageItem
    if ($null -eq $material) {
        return [PSCustomObject]@{
            ok = $false
            reason = 'missingEncryptQueryParam'
        }
    }

    $downloadUri = 'https://novac2c.cdn.weixin.qq.com/c2c/download?encrypted_query_param=' + [System.Uri]::EscapeDataString([string]$material.encryptQueryParam)

    $httpClient = [System.Net.Http.HttpClient]::new()
    try {
        $httpClient.Timeout = [TimeSpan]::FromSeconds($script:InboundImageDownloadTimeoutSec)
        $response = $httpClient.GetAsync($downloadUri).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) {
                return [PSCustomObject]@{
                    ok = $false
                    reason = 'downloadHttpError'
                    statusCode = [int]$response.StatusCode
                    downloadUri = $downloadUri
                }
            }

            $cipherBytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        }
        finally {
            $response.Dispose()
        }
    }
    finally {
        $httpClient.Dispose()
    }

    if ($material.hasKey) {
        $key = ConvertFrom-IlinkAesKey -AesKeyBase64 ([string]$material.aesKeyBase64) -Label 'weixin inbound image'
        $plainBytes = ConvertFrom-AesEcbCiphertext -Ciphertext $cipherBytes -Key $key
    }
    else {
        $plainBytes = $cipherBytes
    }

    $mimeType = Get-IlinkImageMimeType -Bytes $plainBytes
    $extension = Get-IlinkImageExtension -MimeType $mimeType
    $directoryPath = [string](Get-OptionalPropertyValue -InputObject $Config.storage -Name 'inboundMediaDirectory' -DefaultValue (Join-Path $Config.logging.directory 'inbound-media'))
    if (-not (Test-Path -LiteralPath $directoryPath)) {
        New-Item -ItemType Directory -Path $directoryPath -Force | Out-Null
    }

    $messageId = [long](Get-OptionalPropertyValue -InputObject $Update -Name 'message_id' -DefaultValue 0)
    $createTimeMs = [long](Get-OptionalPropertyValue -InputObject $Update -Name 'create_time_ms' -DefaultValue 0)
    $fileName = ('wechat-image-' + $messageId + '-' + $createTimeMs + $extension)
    $filePath = Join-Path $directoryPath $fileName
    [System.IO.File]::WriteAllBytes($filePath, $plainBytes)

    return [PSCustomObject]@{
        ok = $true
        path = $filePath
        mimeType = $mimeType
        byteCount = $plainBytes.Length
        encryptedByteCount = $cipherBytes.Length
        hadDecryptKey = [bool]$material.hasKey
        keySource = [string]$material.keySource
        downloadUri = $downloadUri
    }
}

function Get-AdapterConfig {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Adapter config not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    $config = $raw | ConvertFrom-Json
    if ($null -eq $config) {
        throw "Adapter config is empty: $Path"
    }

    if ([string]::IsNullOrWhiteSpace([string]$config.bridge.requestUri)) {
        throw 'Config value bridge.requestUri is required.'
    }

    $loginResultPath = [string](Get-OptionalPropertyValue -InputObject $config.wechat -Name 'loginResultPath' -DefaultValue (Join-Path $PSScriptRoot 'wechat-login-result.json'))
    if (-not [System.IO.Path]::IsPathRooted($loginResultPath)) {
        $loginResultPath = Join-Path $PSScriptRoot $loginResultPath
    }
    $config.wechat.loginResultPath = Resolve-NormalizedPath -Path $loginResultPath

    if ([string]::IsNullOrWhiteSpace([string]$config.wechat.botToken) -and (Test-Path -LiteralPath $config.wechat.loginResultPath)) {
        $loginRaw = Get-Content -LiteralPath $config.wechat.loginResultPath -Raw -Encoding utf8
        $loginResult = $loginRaw | ConvertFrom-Json
        if ($null -ne $loginResult) {
            $loadedToken = [string](Get-OptionalPropertyValue -InputObject $loginResult -Name 'botToken' -DefaultValue '')
            if (-not [string]::IsNullOrWhiteSpace($loadedToken)) {
                $config.wechat.botToken = $loadedToken
            }

            $loadedBaseUrl = [string](Get-OptionalPropertyValue -InputObject $loginResult -Name 'baseUrl' -DefaultValue '')
            if (-not [string]::IsNullOrWhiteSpace($loadedBaseUrl)) {
                $config.wechat.baseUrl = $loadedBaseUrl
            }

            $loadedBotId = [string](Get-OptionalPropertyValue -InputObject $loginResult -Name 'ilinkBotId' -DefaultValue '')
            if (-not [string]::IsNullOrWhiteSpace($loadedBotId)) {
                Set-OptionalPropertyValue -InputObject $config.wechat -Name 'ilinkBotId' -Value $loadedBotId
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace([string](Get-OptionalPropertyValue -InputObject $config.wechat -Name 'ilinkBotId' -DefaultValue ''))) {
        $botToken = [string](Get-OptionalPropertyValue -InputObject $config.wechat -Name 'botToken' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($botToken) -and $botToken.Contains(':')) {
            Set-OptionalPropertyValue -InputObject $config.wechat -Name 'ilinkBotId' -Value ($botToken.Split(':', 2)[0])
        }
    }

    $statePath = [string](Get-OptionalPropertyValue -InputObject $config.storage -Name 'statePath' -DefaultValue (Join-Path $PSScriptRoot 'adapter-state.json'))
    if (-not [System.IO.Path]::IsPathRooted($statePath)) {
        $statePath = Join-Path $PSScriptRoot $statePath
    }
    $config.storage.statePath = Resolve-NormalizedPath -Path $statePath

    $inboundMediaDirectory = [string](Get-OptionalPropertyValue -InputObject $config.storage -Name 'inboundMediaDirectory' -DefaultValue (Join-Path 'logs' 'inbound-media'))
    if (-not [System.IO.Path]::IsPathRooted($inboundMediaDirectory)) {
        $inboundMediaDirectory = Resolve-NormalizedPath -Path (Join-Path $PSScriptRoot $inboundMediaDirectory)
    }
    Set-OptionalPropertyValue -InputObject $config.storage -Name 'inboundMediaDirectory' -Value $inboundMediaDirectory

    $mockUpdatesPath = [string](Get-OptionalPropertyValue -InputObject $config.mock -Name 'updatesPath' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($mockUpdatesPath) -and -not [System.IO.Path]::IsPathRooted($mockUpdatesPath)) {
        $config.mock.updatesPath = Resolve-NormalizedPath -Path (Join-Path $PSScriptRoot $mockUpdatesPath)
    }

    $mockSentRepliesPath = [string](Get-OptionalPropertyValue -InputObject $config.mock -Name 'sentRepliesPath' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($mockSentRepliesPath) -and -not [System.IO.Path]::IsPathRooted($mockSentRepliesPath)) {
        $config.mock.sentRepliesPath = Resolve-NormalizedPath -Path (Join-Path $PSScriptRoot $mockSentRepliesPath)
    }

    $logsDirectory = [string](Get-OptionalPropertyValue -InputObject $config.logging -Name 'directory' -DefaultValue 'logs')
    if (-not [System.IO.Path]::IsPathRooted($logsDirectory)) {
        $logsDirectory = Resolve-NormalizedPath -Path (Join-Path $PSScriptRoot $logsDirectory)
    }
    $config.logging.directory = $logsDirectory

    return $config
}

function Get-AdapterState {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return New-DefaultAdapterState
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    $state = $raw | ConvertFrom-Json
    if ($null -eq $state) {
        return New-DefaultAdapterState
    }

    if ($state.PSObject.Properties.Match('syncBuf').Count -eq 0) {
        $state | Add-Member -NotePropertyName syncBuf -NotePropertyValue ''
    }

    if ($state.PSObject.Properties.Match('botId').Count -eq 0) {
        $state | Add-Member -NotePropertyName botId -NotePropertyValue ''
    }

    if ($state.PSObject.Properties.Match('latestMediaEntries').Count -eq 0) {
        $state | Add-Member -NotePropertyName latestMediaEntries -NotePropertyValue @()
    }

    return $state
}

function Sync-AdapterStateWithConfig {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [object]$State
    )

    $currentBotId = [string](Get-OptionalPropertyValue -InputObject $Config.wechat -Name 'ilinkBotId' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($currentBotId)) {
        return $false
    }

    $stateBotId = [string](Get-OptionalPropertyValue -InputObject $State -Name 'botId' -DefaultValue '')
    if ($stateBotId -eq $currentBotId) {
        return $false
    }

    $State.botId = $currentBotId
    $State.syncBuf = ''
    $State.lastUpdateId = 0
    return $true
}

function Save-AdapterState {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [object]$State
    )

    $directoryPath = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directoryPath) -and -not (Test-Path -LiteralPath $directoryPath)) {
        New-Item -ItemType Directory -Path $directoryPath -Force | Out-Null
    }

    Write-Utf8File -Path $Path -Content (ConvertTo-AdapterJson -InputObject $State)
}

function Write-AdapterLog {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [object]$Entry
    )

    $directoryPath = [string]$Config.logging.directory
    if (-not (Test-Path -LiteralPath $directoryPath)) {
        New-Item -ItemType Directory -Path $directoryPath -Force | Out-Null
    }

    $logPath = Join-Path $directoryPath 'adapter-log.jsonl'
    Append-Utf8File -Path $logPath -Content ((ConvertTo-AdapterJson -InputObject $Entry) + [Environment]::NewLine)
}

function Get-ExceptionSummary {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $message = [string]$ErrorRecord.Exception.Message
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = [string]$ErrorRecord
    }

    return $message.Trim()
}

function Get-MockUpdates {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [int]$Offset
    )

    $updatesPath = [string]$Config.mock.updatesPath
    if ([string]::IsNullOrWhiteSpace($updatesPath)) {
        return @()
    }

    if (-not (Test-Path -LiteralPath $updatesPath)) {
        throw "Mock updates file not found: $updatesPath"
    }

    $raw = Get-Content -LiteralPath $updatesPath -Raw -Encoding utf8
    $parsed = $raw | ConvertFrom-Json

    $updates = if ($parsed -is [System.Collections.IEnumerable] -and $parsed -isnot [string]) {
        @($parsed)
    }
    elseif ($parsed.PSObject.Properties.Match('result').Count -gt 0) {
        @($parsed.result)
    }
    else {
        @($parsed)
    }

    return @($updates | Where-Object { [int](Get-OptionalPropertyValue -InputObject $_ -Name 'update_id' -DefaultValue 0) -ge $Offset })
}

function New-ApiUri {
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,
        [Parameter(Mandatory)]
        [string]$MethodName,
        [Parameter(Mandatory)]
        [hashtable]$Query
    )

    $builder = [System.UriBuilder]::new((($BaseUrl.TrimEnd('/')) + '/' + $MethodName))
    $queryPairs = New-Object System.Collections.Generic.List[string]
    foreach ($key in $Query.Keys) {
        $value = [string]$Query[$key]
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $queryPairs.Add(([System.Uri]::EscapeDataString([string]$key) + '=' + [System.Uri]::EscapeDataString($value)))
    }

    $builder.Query = ($queryPairs -join '&')
    return $builder.Uri.AbsoluteUri
}

function Invoke-IlinkPost {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [string]$Endpoint,
        [Parameter(Mandatory)]
        [object]$Body,
        [int]$TimeoutSec = $script:DefaultIlinkPostTimeoutSec
    )

    $baseUrl = [string]$Config.wechat.baseUrl
    $botToken = [string]$Config.wechat.botToken
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        throw 'Config value wechat.baseUrl is required when mock.enabled is false.'
    }
    if ([string]::IsNullOrWhiteSpace($botToken)) {
        throw 'Config value wechat.botToken is required when mock.enabled is false.'
    }

    $uri = (($baseUrl.TrimEnd('/')) + '/' + $Endpoint.TrimStart('/'))
    $jsonBody = $Body | ConvertTo-Json -Depth 10 -Compress
    $headers = @{
        'AuthorizationType' = 'ilink_bot_token'
        'Authorization' = ('Bearer ' + $botToken)
        'X-WECHAT-UIN' = (New-RandomWechatUin)
    }
    $routeTag = [string](Get-OptionalPropertyValue -InputObject $Config.wechat -Name 'routeTag' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($routeTag)) {
        $headers['SKRouteTag'] = $routeTag
    }

    return Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/json' -Body $jsonBody -TimeoutSec $TimeoutSec
}

function Get-NextUpdateBatch {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [object]$State
    )

    if ([bool](Get-OptionalPropertyValue -InputObject $Config.mock -Name 'enabled' -DefaultValue $false)) {
        $offset = [int]$State.lastUpdateId + 1
        return [PSCustomObject]@{
            updates = @(Get-MockUpdates -Config $Config -Offset $offset)
            syncBuf = [string](Get-OptionalPropertyValue -InputObject $State -Name 'syncBuf' -DefaultValue '')
        }
    }

    $timeoutSec = [int](Get-OptionalPropertyValue -InputObject $Config.wechat -Name 'pollTimeoutSec' -DefaultValue $script:DefaultPollTimeoutSec)
    $timeoutMs = $timeoutSec * $script:MillisecondsPerSecond
    $response = Invoke-IlinkPost -Config $Config -Endpoint 'ilink/bot/getupdates' -TimeoutSec ($timeoutSec + $script:PollTimeoutBufferSec) -Body ([PSCustomObject]@{
        get_updates_buf = [string](Get-OptionalPropertyValue -InputObject $State -Name 'syncBuf' -DefaultValue '')
        base_info = [PSCustomObject]@{
            channel_version = 'cc-connect-weixin/1.0'
        }
        longpolling_timeout_ms = $timeoutMs
    })

    $currentSyncBuf = [string](Get-OptionalPropertyValue -InputObject $State -Name 'syncBuf' -DefaultValue '')

    return [PSCustomObject]@{
        updates = @((Get-OptionalPropertyValue -InputObject $response -Name 'msgs' -DefaultValue @()))
        syncBuf = [string](Get-OptionalPropertyValue -InputObject $response -Name 'get_updates_buf' -DefaultValue $currentSyncBuf)
        ret = [int](Get-OptionalPropertyValue -InputObject $response -Name 'ret' -DefaultValue 0)
        errcode = [int](Get-OptionalPropertyValue -InputObject $response -Name 'errcode' -DefaultValue 0)
        errmsg = [string](Get-OptionalPropertyValue -InputObject $response -Name 'errmsg' -DefaultValue '')
    }
}

function Convert-UpdateToBridgePayload {
    param(
        [Parameter(Mandatory)]
        [object]$Update,
        [Parameter(Mandatory)]
        [object]$Config
    )

    $isMock = [bool](Get-OptionalPropertyValue -InputObject $Config.mock -Name 'enabled' -DefaultValue $false)
    if ($isMock) {
        $message = Get-OptionalPropertyValue -InputObject $Update -Name 'message'
        if ($null -eq $message) {
            return $null
        }

        $text = [string](Get-OptionalPropertyValue -InputObject $message -Name 'text' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }

        $chat = Get-OptionalPropertyValue -InputObject $message -Name 'chat'
        $from = Get-OptionalPropertyValue -InputObject $message -Name 'from'
        $chatId = [string](Get-OptionalPropertyValue -InputObject $chat -Name 'id' -DefaultValue '')
        $fromId = [string](Get-OptionalPropertyValue -InputObject $from -Name 'id' -DefaultValue $chatId)

        if ([string]::IsNullOrWhiteSpace($chatId)) {
            return $null
        }

        $mode = if ($text -match '(^|\s)/apply(\s|$)') { 'apply' } else { 'read' }
        $sessionPrefix = [string](Get-OptionalPropertyValue -InputObject $Config.bridge -Name 'sessionPrefix' -DefaultValue 'wechat')

        return [PSCustomObject]@{
            updateId = [int](Get-OptionalPropertyValue -InputObject $Update -Name 'update_id' -DefaultValue 0)
            chatId = $chatId
            peerUserId = $chatId
            text = $text
            userId = $fromId
            sessionId = ($sessionPrefix + '-' + $chatId)
            mode = $mode
            contextToken = ''
        }
    }

    $itemList = @(Get-OptionalPropertyValue -InputObject $Update -Name 'item_list' -DefaultValue @())
    $text = Get-BodyFromItemList -Items $itemList
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $fromId = [string](Get-OptionalPropertyValue -InputObject $Update -Name 'from_user_id' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($fromId)) {
        return $null
    }

    $mode = if ($text -match '(^|\s)/apply(\s|$)') { 'apply' } else { 'read' }
    $sessionPrefix = [string](Get-OptionalPropertyValue -InputObject $Config.bridge -Name 'sessionPrefix' -DefaultValue 'wechat')
    $messageId = [long](Get-OptionalPropertyValue -InputObject $Update -Name 'message_id' -DefaultValue 0)
    $seq = [long](Get-OptionalPropertyValue -InputObject $Update -Name 'seq' -DefaultValue 0)
    $createTimeMs = [long](Get-OptionalPropertyValue -InputObject $Update -Name 'create_time_ms' -DefaultValue 0)
    $clientId = [string](Get-OptionalPropertyValue -InputObject $Update -Name 'client_id' -DefaultValue '')
    $compoundUpdateId = [string]::Join('|', @($fromId, $messageId, $seq, $createTimeMs, $clientId))

    return [PSCustomObject]@{
        updateId = $compoundUpdateId
        chatId = $fromId
        peerUserId = $fromId
        text = $text
        userId = $fromId
        sessionId = ($sessionPrefix + '-' + $fromId)
        mode = $mode
        contextToken = [string](Get-OptionalPropertyValue -InputObject $Update -Name 'context_token' -DefaultValue '')
    }
}

function New-MediaOnlyBridgePayload {
    param(
        [Parameter(Mandatory)]
        [object]$Update,
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [object]$SavedMedia
    )

    if (-not [bool](Get-OptionalPropertyValue -InputObject $SavedMedia -Name 'ok' -DefaultValue $false)) {
        return $null
    }

    $fromId = [string](Get-OptionalPropertyValue -InputObject $Update -Name 'from_user_id' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($fromId)) {
        return $null
    }

    $sessionPrefix = [string](Get-OptionalPropertyValue -InputObject $Config.bridge -Name 'sessionPrefix' -DefaultValue 'wechat')
    $messageId = [long](Get-OptionalPropertyValue -InputObject $Update -Name 'message_id' -DefaultValue 0)
    $seq = [long](Get-OptionalPropertyValue -InputObject $Update -Name 'seq' -DefaultValue 0)
    $createTimeMs = [long](Get-OptionalPropertyValue -InputObject $Update -Name 'create_time_ms' -DefaultValue 0)
    $clientId = [string](Get-OptionalPropertyValue -InputObject $Update -Name 'client_id' -DefaultValue '')
    $compoundUpdateId = [string]::Join('|', @($fromId, $messageId, $seq, $createTimeMs, $clientId))

    return [PSCustomObject]@{
        updateId = $compoundUpdateId
        chatId = $fromId
        peerUserId = $fromId
        text = ''
        userId = $fromId
        sessionId = ($sessionPrefix + '-' + $fromId)
        mode = 'read'
        contextToken = [string](Get-OptionalPropertyValue -InputObject $Update -Name 'context_token' -DefaultValue '')
        media = @(New-BridgeImageMediaItem -Entry $SavedMedia -Source 'wechat')
    }
}

function New-BridgeImageMediaItem {
    param(
        [Parameter(Mandatory)]
        [object]$Entry,
        [Parameter(Mandatory)]
        [string]$Source
    )

    return [PSCustomObject]@{
        kind = 'image'
        path = [string](Get-OptionalPropertyValue -InputObject $Entry -Name 'path' -DefaultValue '')
        mimeType = [string](Get-OptionalPropertyValue -InputObject $Entry -Name 'mimeType' -DefaultValue '')
        byteCount = [int](Get-OptionalPropertyValue -InputObject $Entry -Name 'byteCount' -DefaultValue 0)
        encryptedByteCount = [int](Get-OptionalPropertyValue -InputObject $Entry -Name 'encryptedByteCount' -DefaultValue 0)
        keySource = [string](Get-OptionalPropertyValue -InputObject $Entry -Name 'keySource' -DefaultValue '')
        source = $Source
    }
}

function Test-TeamsImageOnlySendIntent {
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

function Set-LatestSavedMediaEntry {
    param(
        [Parameter(Mandatory)]
        [object]$State,
        [Parameter(Mandatory)]
        [object]$Payload,
        [Parameter(Mandatory)]
        [object]$SavedMedia
    )

    if (-not [bool](Get-OptionalPropertyValue -InputObject $SavedMedia -Name 'ok' -DefaultValue $false)) {
        return
    }

    $path = [string](Get-OptionalPropertyValue -InputObject $SavedMedia -Name 'path' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($path)) {
        return
    }

    $existingEntries = @((Get-OptionalPropertyValue -InputObject $State -Name 'latestMediaEntries' -DefaultValue @()))
    $userId = [string](Get-OptionalPropertyValue -InputObject $Payload -Name 'userId' -DefaultValue '')
    $sessionId = [string](Get-OptionalPropertyValue -InputObject $Payload -Name 'sessionId' -DefaultValue '')
    $nextEntries = New-Object System.Collections.Generic.List[object]

    foreach ($entry in $existingEntries) {
        if ($null -eq $entry) {
            continue
        }

        $entryUserId = [string](Get-OptionalPropertyValue -InputObject $entry -Name 'userId' -DefaultValue '')
        $entrySessionId = [string](Get-OptionalPropertyValue -InputObject $entry -Name 'sessionId' -DefaultValue '')
        if (
            (-not [string]::IsNullOrWhiteSpace($sessionId) -and $entrySessionId -eq $sessionId) -or
            (-not [string]::IsNullOrWhiteSpace($userId) -and $entryUserId -eq $userId)
        ) {
            continue
        }

        $nextEntries.Add($entry)
    }

    $nextEntries.Add([PSCustomObject]@{
        userId = $userId
        sessionId = $sessionId
        path = $path
        mimeType = [string](Get-OptionalPropertyValue -InputObject $SavedMedia -Name 'mimeType' -DefaultValue '')
        byteCount = [int](Get-OptionalPropertyValue -InputObject $SavedMedia -Name 'byteCount' -DefaultValue 0)
        encryptedByteCount = [int](Get-OptionalPropertyValue -InputObject $SavedMedia -Name 'encryptedByteCount' -DefaultValue 0)
        keySource = [string](Get-OptionalPropertyValue -InputObject $SavedMedia -Name 'keySource' -DefaultValue '')
        timestamp = (Get-Date).ToString('o')
    })

    $State.latestMediaEntries = @($nextEntries)
}

function Get-LatestSavedMediaEntryFromDisk {
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )

    $directoryPath = [string](Get-OptionalPropertyValue -InputObject $Config.storage -Name 'inboundMediaDirectory' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($directoryPath) -or -not (Test-Path -LiteralPath $directoryPath)) {
        return $null
    }

    $candidate = Get-ChildItem -LiteralPath $directoryPath -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        return $null
    }

    return [PSCustomObject]@{
        userId = ''
        sessionId = ''
        path = $candidate.FullName
        mimeType = ''
        byteCount = [int]$candidate.Length
        encryptedByteCount = 0
        keySource = 'disk-fallback'
        timestamp = $candidate.LastWriteTimeUtc.ToString('o')
    }
}

function Add-CachedMediaToPayloadIfNeeded {
    param(
        [Parameter(Mandatory)]
        [object]$Payload,
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [object]$State
    )

    if (-not (Test-TeamsImageOnlySendIntent -Text ([string](Get-OptionalPropertyValue -InputObject $Payload -Name 'text' -DefaultValue '')))) {
        return $false
    }

    $existingMedia = @((Get-OptionalPropertyValue -InputObject $Payload -Name 'media' -DefaultValue @()))
    if ($existingMedia.Count -gt 0) {
        return $false
    }

    $userId = [string](Get-OptionalPropertyValue -InputObject $Payload -Name 'userId' -DefaultValue '')
    $sessionId = [string](Get-OptionalPropertyValue -InputObject $Payload -Name 'sessionId' -DefaultValue '')
    $entries = @((Get-OptionalPropertyValue -InputObject $State -Name 'latestMediaEntries' -DefaultValue @()))
    $match = $null

    foreach ($entry in $entries) {
        if ($null -eq $entry) {
            continue
        }

        $entrySessionId = [string](Get-OptionalPropertyValue -InputObject $entry -Name 'sessionId' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($sessionId) -and $entrySessionId -eq $sessionId) {
            $match = $entry
            break
        }
    }

    if ($null -eq $match) {
        foreach ($entry in $entries) {
            if ($null -eq $entry) {
                continue
            }

            $entryUserId = [string](Get-OptionalPropertyValue -InputObject $entry -Name 'userId' -DefaultValue '')
            if (-not [string]::IsNullOrWhiteSpace($userId) -and $entryUserId -eq $userId) {
                $match = $entry
                break
            }
        }
    }

    if ($null -eq $match) {
        $match = Get-LatestSavedMediaEntryFromDisk -Config $Config
    }

    if ($null -eq $match) {
        return $false
    }

    $path = [string](Get-OptionalPropertyValue -InputObject $match -Name 'path' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
        return $false
    }

    Set-OptionalPropertyValue -InputObject $Payload -Name 'media' -Value @(New-BridgeImageMediaItem -Entry $match -Source 'wechat-cache')

    return $true
}

function Test-ProcessingNoticeNeeded {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $patterns = @(
        '搜索',
        '查找',
        '找到',
        '执行',
        '打开',
        '启动',
        '发送',
        '发给',
        'teams',
        'github',
        '链接',
        'textbox\.cs',
        '\bsearch\b',
        '\bfind\b',
        '\bopen\b',
        '\bsend\b',
        '\bteams\b',
        '\bgithub\b'
    )

    foreach ($pattern in $patterns) {
        if ($Text -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-ProcessingNoticeText {
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )

    $configuredText = [string](Get-OptionalPropertyValue -InputObject $Config.wechat -Name 'processingNoticeText' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($configuredText)) {
        return $configuredText.Trim()
    }

    return '收到，正在处理中。若涉及搜索或桌面操作，我处理完成后再把结果发给你。'
}

function Send-ProcessingNotice {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [object]$Payload
    )

    if (-not [bool](Get-OptionalPropertyValue -InputObject $Config.wechat -Name 'sendReplies' -DefaultValue $true)) {
        return
    }

    if (-not [bool](Get-OptionalPropertyValue -InputObject $Config.wechat -Name 'sendProcessingNotices' -DefaultValue $true)) {
        return
    }

    if (-not (Test-ProcessingNoticeNeeded -Text ([string]$Payload.text))) {
        return
    }

    $noticeText = Get-ProcessingNoticeText -Config $Config
    if ([string]::IsNullOrWhiteSpace($noticeText)) {
        return
    }

    if ([bool](Get-OptionalPropertyValue -InputObject $Config.mock -Name 'enabled' -DefaultValue $false)) {
        Send-AdapterReply -Config $Config -ChatId ([string]$Payload.chatId) -ReplyText $noticeText
        return
    }

    Send-RealWechatReply -Config $Config -PeerUserId ([string]$Payload.peerUserId) -ReplyText $noticeText -ContextToken ([string]$Payload.contextToken)
}

function Invoke-BridgeMessage {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [object]$Payload
    )

    $requestBody = [PSCustomObject]@{
        text = $Payload.text
        userId = $Payload.userId
        sessionId = $Payload.sessionId
        mode = $Payload.mode
    }
    if ($Payload.PSObject.Properties.Match('media').Count -gt 0) {
        $requestBody | Add-Member -NotePropertyName media -NotePropertyValue @($Payload.media)
    }

    $json = $requestBody | ConvertTo-Json -Depth 6
    return Invoke-RestMethod -Uri ([string]$Config.bridge.requestUri) -Method Post -ContentType 'application/json; charset=utf-8' -Body $json
}

function Send-AdapterReply {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [string]$ChatId,
        [Parameter(Mandatory)]
        [string]$ReplyText
    )

    if ([string]::IsNullOrWhiteSpace($ReplyText)) {
        return
    }

    if ([bool](Get-OptionalPropertyValue -InputObject $Config.mock -Name 'enabled' -DefaultValue $false)) {
        $sentRepliesPath = [string](Get-OptionalPropertyValue -InputObject $Config.mock -Name 'sentRepliesPath' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($sentRepliesPath)) {
            return
        }

        $directoryPath = Split-Path -Parent $sentRepliesPath
        if (-not [string]::IsNullOrWhiteSpace($directoryPath) -and -not (Test-Path -LiteralPath $directoryPath)) {
            New-Item -ItemType Directory -Path $directoryPath -Force | Out-Null
        }

        Append-Utf8File -Path $sentRepliesPath -Content ((ConvertTo-AdapterJson -InputObject ([PSCustomObject]@{
            chatId = $ChatId
            text = $ReplyText
            sentAt = (Get-Date).ToString('o')
        })) + [Environment]::NewLine)
        return
    }

    throw 'Real send requires the payload-based overload with context_token.'
}

function Send-RealWechatReply {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [string]$PeerUserId,
        [Parameter(Mandatory)]
        [string]$ReplyText,
        [Parameter(Mandatory)]
        [string]$ContextToken
    )

    if ([string]::IsNullOrWhiteSpace($ReplyText)) {
        return
    }
    if ([string]::IsNullOrWhiteSpace($ContextToken)) {
        throw "Missing context_token for peer $PeerUserId"
    }

    Invoke-IlinkPost -Config $Config -Endpoint 'ilink/bot/sendmessage' -Body ([PSCustomObject]@{
        msg = [PSCustomObject]@{
            from_user_id = ''
            to_user_id = $PeerUserId
            client_id = ('cc-' + (New-RandomHex -ByteCount 6))
            message_type = 2
            message_state = 2
            item_list = @(
                [PSCustomObject]@{
                    type = 1
                    text_item = [PSCustomObject]@{
                        text = $ReplyText
                    }
                }
            )
            context_token = $ContextToken
        }
        base_info = [PSCustomObject]@{
            channel_version = 'cc-connect-weixin/1.0'
        }
    }) | Out-Null
}

function Invoke-UpdateProcessing {
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        [Parameter(Mandatory)]
        [object]$Update,
        [Parameter(Mandatory)]
        [object]$State
    )

    $payload = Convert-UpdateToBridgePayload -Update $Update -Config $Config
    if ($null -eq $payload) {
        if (-not [bool](Get-OptionalPropertyValue -InputObject $Config.mock -Name 'enabled' -DefaultValue $false)) {
            $savedMedia = $null
            $bridgeResponse = $null
            try {
                $savedMedia = Save-IlinkInboundImage -Config $Config -Update $Update
            }
            catch {
                $savedMedia = [PSCustomObject]@{
                    ok = $false
                    reason = 'imagePersistenceError'
                    error = (Get-ExceptionSummary -ErrorRecord $_)
                }
            }

            $mediaPayload = New-MediaOnlyBridgePayload -Update $Update -Config $Config -SavedMedia $savedMedia
            if ($null -ne $mediaPayload) {
                Set-LatestSavedMediaEntry -State $State -Payload $mediaPayload -SavedMedia $savedMedia
                $bridgeResponse = Invoke-BridgeMessage -Config $Config -Payload $mediaPayload
                $reply = [string](Get-OptionalPropertyValue -InputObject $bridgeResponse -Name 'reply' -DefaultValue '')
                if (
                    [bool](Get-OptionalPropertyValue -InputObject $Config.wechat -Name 'sendReplies' -DefaultValue $true) -and
                    -not [string]::IsNullOrWhiteSpace($reply)
                ) {
                    Send-RealWechatReply -Config $Config -PeerUserId ([string]$mediaPayload.peerUserId) -ReplyText $reply -ContextToken ([string]$mediaPayload.contextToken)
                }
            }

            Write-AdapterLog -Config $Config -Entry ([PSCustomObject]@{
                timestamp = (Get-Date).ToString('o')
                event = 'mediaOnlyUpdate'
                reason = 'noSupportedTextBody'
                update = Get-UpdateDiagnosticSummary -Update $Update
                savedMedia = $savedMedia
                bridgeResponse = $bridgeResponse
            })
        }

        $State.lastUpdateId = [Math]::Max([int]$State.lastUpdateId, [int](Get-OptionalPropertyValue -InputObject $Update -Name 'update_id' -DefaultValue 0))
        return
    }

    $attachedCachedMedia = Add-CachedMediaToPayloadIfNeeded -Payload $payload -Config $Config -State $State

    Send-ProcessingNotice -Config $Config -Payload $payload
    $bridgeResponse = Invoke-BridgeMessage -Config $Config -Payload $payload
    $reply = [string](Get-OptionalPropertyValue -InputObject $bridgeResponse -Name 'reply' -DefaultValue '')
    if ([bool](Get-OptionalPropertyValue -InputObject $Config.wechat -Name 'sendReplies' -DefaultValue $true)) {
        if ([bool](Get-OptionalPropertyValue -InputObject $Config.mock -Name 'enabled' -DefaultValue $false)) {
            Send-AdapterReply -Config $Config -ChatId ([string]$payload.chatId) -ReplyText $reply
        }
        else {
            Send-RealWechatReply -Config $Config -PeerUserId ([string]$payload.peerUserId) -ReplyText $reply -ContextToken ([string]$payload.contextToken)
        }
    }

    if ([bool](Get-OptionalPropertyValue -InputObject $Config.mock -Name 'enabled' -DefaultValue $false)) {
        $State.lastUpdateId = [Math]::Max([int]$State.lastUpdateId, [int]$payload.updateId)
    }

    Write-AdapterLog -Config $Config -Entry ([PSCustomObject]@{
        timestamp = (Get-Date).ToString('o')
        updateId = $payload.updateId
        chatId = $payload.chatId
        text = $payload.text
        attachedCachedMedia = $attachedCachedMedia
        processingNoticeSent = (Test-ProcessingNoticeNeeded -Text ([string]$payload.text))
        bridgeResponse = $bridgeResponse
    })
}

function Main {
    $config = Get-AdapterConfig -Path $ConfigPath
    $state = Get-AdapterState -Path ([string]$config.storage.statePath)
    if (Sync-AdapterStateWithConfig -Config $config -State $state) {
        Save-AdapterState -Path ([string]$config.storage.statePath) -State $state
    }

    $pollCount = 0
    Write-Host "Personal WeChat adapter started."
    Write-Host "Bridge URI: $($config.bridge.requestUri)"
    if ([bool](Get-OptionalPropertyValue -InputObject $config.mock -Name 'enabled' -DefaultValue $false)) {
        Write-Host "Mock mode: enabled"
    }

    while ($true) {
        if ($RunOnce.IsPresent -and $pollCount -ge 1) {
            break
        }
        if ($MaxPolls -gt 0 -and $pollCount -ge $MaxPolls) {
            break
        }

        try {
            $previousSyncBuf = [string](Get-OptionalPropertyValue -InputObject $state -Name 'syncBuf' -DefaultValue '')
            $batch = Get-NextUpdateBatch -Config $config -State $state
            if ($batch.PSObject.Properties.Match('syncBuf').Count -gt 0) {
                $state.syncBuf = [string]$batch.syncBuf
            }
            $updates = @($batch.updates)

            if ((-not [bool](Get-OptionalPropertyValue -InputObject $config.mock -Name 'enabled' -DefaultValue $false)) -and
                $updates.Count -eq 0 -and
                -not [string]::Equals($previousSyncBuf, [string]$state.syncBuf, [System.StringComparison]::Ordinal)) {
                Write-AdapterLog -Config $config -Entry ([PSCustomObject]@{
                    timestamp = (Get-Date).ToString('o')
                    event = 'emptyBatchAdvancedCursor'
                    previousSyncBuf = $previousSyncBuf
                    nextSyncBuf = [string]$state.syncBuf
                    ret = [int](Get-OptionalPropertyValue -InputObject $batch -Name 'ret' -DefaultValue 0)
                    errcode = [int](Get-OptionalPropertyValue -InputObject $batch -Name 'errcode' -DefaultValue 0)
                    errmsg = [string](Get-OptionalPropertyValue -InputObject $batch -Name 'errmsg' -DefaultValue '')
                })
            }

            foreach ($update in $updates) {
                Invoke-UpdateProcessing -Config $config -Update $update -State $state
                Save-AdapterState -Path ([string]$config.storage.statePath) -State $state
            }

            if ($updates.Count -eq 0) {
                Save-AdapterState -Path ([string]$config.storage.statePath) -State $state
            }

            $pollCount++
        }
        catch {
            $errorSummary = Get-ExceptionSummary -ErrorRecord $_
            Write-Warning ("Adapter poll failed: " + $errorSummary)
            Write-AdapterLog -Config $config -Entry ([PSCustomObject]@{
                timestamp = (Get-Date).ToString('o')
                level = 'error'
                stage = 'poll'
                message = $errorSummary
                bridgeUri = [string]$config.bridge.requestUri
                wechatBaseUrl = [string](Get-OptionalPropertyValue -InputObject $config.wechat -Name 'baseUrl' -DefaultValue '')
            })

            Start-Sleep -Milliseconds ([int](Get-OptionalPropertyValue -InputObject $config.wechat -Name 'pollIntervalMs' -DefaultValue 1500))

            if ($RunOnce.IsPresent) {
                throw
            }

            continue
        }

        if ([bool](Get-OptionalPropertyValue -InputObject $config.mock -Name 'enabled' -DefaultValue $false)) {
            if ($RunOnce.IsPresent) {
                break
            }
        }

        Start-Sleep -Milliseconds ([int](Get-OptionalPropertyValue -InputObject $config.wechat -Name 'pollIntervalMs' -DefaultValue 1500))
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}