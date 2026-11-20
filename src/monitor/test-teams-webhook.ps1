<#
.SYNOPSIS
  Sends a test Adaptive Card to the Teams webhook configured in $env:TEAMS_WEBHOOK_URL.
.USAGE
  From the repo root, in ONE PowerShell session:
  . ./config.ps1
  ./src/monitor/test-teams-webhook.ps1
.NOTES
  Posts a real message to the configured Teams channel.
  The body is sent as explicit UTF-8 bytes: Windows PowerShell 5.1's Invoke-RestMethod encodes
  a [string] body with the system codepage (docs/context.md, technical gotcha 7).
  Keep this file pure ASCII: PS 5.1 parses BOM-less .ps1 files as Windows-1252.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $env:TEAMS_WEBHOOK_URL) {
    throw "TEAMS_WEBHOOK_URL is not set. Define it in config.ps1 (never hardcode it) and dot-source config.ps1 before running this script."
}

$card = @{
    type        = 'message'
    attachments = @(
        @{
            contentType = 'application/vnd.microsoft.card.adaptive'
            content     = @{
                '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
                type      = 'AdaptiveCard'
                version   = '1.4'
                body      = @(
                    @{
                        type   = 'TextBlock'
                        text   = 'ADO Monitor: webhook de prueba'
                        weight = 'Bolder'
                        size   = 'Medium'
                    },
                    @{
                        type = 'TextBlock'
                        text = 'Si ves este mensaje, el webhook de Teams esta configurado correctamente.'
                        wrap = $true
                    }
                )
            }
        }
    )
}

$json  = $card | ConvertTo-Json -Depth 10
$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
Invoke-RestMethod -Method POST -Uri $env:TEAMS_WEBHOOK_URL -Body $bytes -ContentType 'application/json; charset=utf-8'
Write-Host "(ok) Test message sent to Teams webhook" -ForegroundColor Green
