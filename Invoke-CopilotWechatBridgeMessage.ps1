#!/usr/bin/env pwsh
<#!
.SYNOPSIS
Sends a local test message to the Copilot WeChat bridge.

.DESCRIPTION
Posts a JSON payload to the local bridge so the HTTP execution path can be
validated before connecting a real WeChat adapter.

.PARAMETER Text
The message text to send.

.PARAMETER UserId
The caller identifier used by bridge allow-list validation.

.PARAMETER SessionId
Optional session name passed to the bridge.

.PARAMETER Mode
Execution mode. Use 'read' for analysis-only or 'apply' to allow edits.

.PARAMETER Route
Optional forced route. Use 'gui' to test the GUI fallback path.

.PARAMETER Uri
Bridge endpoint URI.

.EXAMPLE
./Invoke-CopilotWechatBridgeMessage.ps1 -Text 'Summarize this repo'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Text,

    [string]$UserId = 'local-user',

    [string]$SessionId = 'local-session',

    [ValidateSet('read', 'apply')]
    [string]$Mode = 'read',

    [ValidateSet('', 'gui')]
    [string]$Route = '',

    [string]$Uri = 'http://127.0.0.1:8766/message'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$payload = [PSCustomObject]@{
    text = $Text
    userId = $UserId
    sessionId = $SessionId
    mode = $Mode
}

if (-not [string]::IsNullOrWhiteSpace($Route)) {
    $payload | Add-Member -NotePropertyName route -NotePropertyValue $Route
}

$body = $payload | ConvertTo-Json -Depth 5
$result = Invoke-RestMethod -Uri $Uri -Method Post -ContentType 'application/json; charset=utf-8' -Body $body
$result | ConvertTo-Json -Depth 8