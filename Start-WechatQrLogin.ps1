#!/usr/bin/env pwsh
<#!
.SYNOPSIS
Starts a real personal WeChat QR login flow against the ilink gateway.

.DESCRIPTION
Fetches a QR code from the ilink personal WeChat gateway, opens the QR in the
default browser for scanning, polls the QR status until confirmation, and saves
the acquired token payload to a local JSON file.

.PARAMETER ApiUrl
The ilink API base URL.

.PARAMETER BotType
The bot_type query parameter for get_bot_qrcode.

.PARAMETER RouteTag
Optional SKRouteTag header value.

.PARAMETER TimeoutSec
Maximum time to wait for scanning and confirmation.

.PARAMETER OutputPath
Where to save the acquired token payload as JSON.

.PARAMETER OpenInBrowser
Open the QR URL in the default browser.

.EXAMPLE
./Start-WechatQrLogin.ps1 -OpenInBrowser
#>

[CmdletBinding()]
param(
    [string]$ApiUrl = 'https://ilinkai.weixin.qq.com',
    [string]$BotType = '3',
    [string]$RouteTag = '',
    [ValidateRange(10, 3600)]
    [int]$TimeoutSec = 480,
    [string]$OutputPath = (Join-Path $PSScriptRoot 'wechat-login-result.json'),
    [switch]$OpenInBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
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

function Write-Utf8File {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (Get-Utf8NoBomEncoding))
}

function New-IlinkUri {
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,
        [Parameter(Mandatory)]
        [string]$RelativePath,
        [hashtable]$Query = @{}
    )

    $builder = [System.UriBuilder]::new((($BaseUrl.TrimEnd('/')) + '/' + $RelativePath.TrimStart('/')))
    $pairs = New-Object System.Collections.Generic.List[string]
    foreach ($key in $Query.Keys) {
        $value = [string]$Query[$key]
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $pairs.Add(([System.Uri]::EscapeDataString([string]$key) + '=' + [System.Uri]::EscapeDataString($value)))
    }

    $builder.Query = ($pairs -join '&')
    return $builder.Uri.AbsoluteUri
}

function Invoke-IlinkGet {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,
        [AllowNull()]
        [string]$RouteTagValue,
        [int]$Timeout = 30
    )

    $headers = @{
        'iLink-App-ClientVersion' = '1'
    }
    if (-not [string]::IsNullOrWhiteSpace($RouteTagValue)) {
        $headers['SKRouteTag'] = $RouteTagValue
    }

    return Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers -TimeoutSec $Timeout
}

function Get-WechatBotQrCode {
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,
        [Parameter(Mandatory)]
        [string]$BotTypeValue,
        [AllowNull()]
        [string]$RouteTagValue
    )

    $uri = New-IlinkUri -BaseUrl $BaseUrl -RelativePath 'ilink/bot/get_bot_qrcode' -Query @{
        bot_type = $BotTypeValue
    }
    return Invoke-IlinkGet -Uri $uri -RouteTagValue $RouteTagValue -Timeout 30
}

function Get-WechatQrStatus {
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,
        [Parameter(Mandatory)]
        [string]$QrKey,
        [AllowNull()]
        [string]$RouteTagValue
    )

    $uri = New-IlinkUri -BaseUrl $BaseUrl -RelativePath 'ilink/bot/get_qrcode_status' -Query @{
        qrcode = $QrKey
    }
    return Invoke-IlinkGet -Uri $uri -RouteTagValue $RouteTagValue -Timeout 40
}

function Save-LoginResult {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [object]$Result
    )

    $directoryPath = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directoryPath) -and -not (Test-Path -LiteralPath $directoryPath)) {
        New-Item -ItemType Directory -Path $directoryPath -Force | Out-Null
    }

    Write-Utf8File -Path $Path -Content ($Result | ConvertTo-Json -Depth 6)
}

function Main {
    $qr = Get-WechatBotQrCode -BaseUrl $ApiUrl -BotTypeValue $BotType -RouteTagValue $RouteTag
    $qrKey = [string]$qr.qrcode
    $qrUrl = [string]$qr.qrcode_img_content

    if ([string]::IsNullOrWhiteSpace($qrKey) -or [string]::IsNullOrWhiteSpace($qrUrl)) {
        throw 'QR login endpoint returned an incomplete payload.'
    }

    Write-Host '请用微信扫描刚弹出的二维码。'
    Write-Host "QR URL: $qrUrl"

    if ($OpenInBrowser.IsPresent) {
        Start-Process $qrUrl | Out-Null
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $printedScanned = $false

    while ((Get-Date) -lt $deadline) {
        $status = Get-WechatQrStatus -BaseUrl $ApiUrl -QrKey $qrKey -RouteTagValue $RouteTag
        $state = [string]$status.status

        switch ($state) {
            'wait' {
                Start-Sleep -Seconds 1
                continue
            }
            'scaned' {
                if (-not $printedScanned) {
                    Write-Host '已扫码，请在手机上确认登录。'
                    $printedScanned = $true
                }
                Start-Sleep -Seconds 1
                continue
            }
            'confirmed' {
                $result = [PSCustomObject]@{
                    status = $state
                    botToken = [string](Get-OptionalPropertyValue -InputObject $status -Name 'bot_token' -DefaultValue '')
                    ilinkBotId = [string](Get-OptionalPropertyValue -InputObject $status -Name 'ilink_bot_id' -DefaultValue '')
                    baseUrl = [string](Get-OptionalPropertyValue -InputObject $status -Name 'base_url' -DefaultValue '')
                    ilinkUserId = [string](Get-OptionalPropertyValue -InputObject $status -Name 'ilink_user_id' -DefaultValue '')
                    qrKey = $qrKey
                    qrUrl = $qrUrl
                    confirmedAt = (Get-Date).ToString('o')
                }

                Save-LoginResult -Path $OutputPath -Result $result
                Write-Host '已确认登录，结果已保存。'
                Write-Output ($result | ConvertTo-Json -Depth 6)
                return
            }
            'expired' {
                throw '二维码已过期，请重新运行脚本。'
            }
            default {
                Start-Sleep -Seconds 1
            }
        }
    }

    throw '等待扫码超时。'
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}