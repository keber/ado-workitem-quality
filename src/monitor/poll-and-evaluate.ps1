<#
.SYNOPSIS
  Polls Azure DevOps for new User Story / Task work items in the configured area path,
  evaluates each one for vagueness/ambiguity/missing Acceptance Criteria via a Claude Code
  headless call, and posts free-text findings to a Teams channel.

.USAGE
  powershell -NoProfile -ExecutionPolicy Bypass -File src/monitor/poll-and-evaluate.ps1 -Project <name>

.PARAMETER Project
  Mandatory. Project name (lowercase letters, digits and dashes only, it builds file paths).
  Project config is read from projects/<name>/config.json and the cursor is kept in
  state/<name>/cursor.json.

.PARAMETER InitialLookbackDays
  Only used the first time the script runs (no cursor file yet) -- how far back to look
  for work items so nothing created just before the monitor was set up gets skipped.
  Overrides the "initialLookbackDays" value in config.json when supplied.

.PARAMETER WorkItemId
  Re-process specific work items by ID (e.g. to re-send a card). Skips the WIQL query and
  does NOT read or update the cursor, so the regular polling schedule is unaffected.
  Example: -WorkItemId 1004  or  -WorkItemId 1004,1005

.NOTES
  config.ps1, the ado-powershell skill, and the actual ADO queries must live in the SAME
  PowerShell invocation -- see docs/context.md, technical gotcha 1.
  Splitting this into "dot-source session elsewhere, then call this as a child script"
  breaks $script:AdoSession resolution inside ado-workitems.ps1's default parameter values.
  That is why this script dot-sources config.ps1 and load.ps1 itself instead of assuming
  the caller already did it.
  Requires projects/<name>/config.json (run src/monitor/setup.ps1 -Project <name> to create
  it), config.ps1 at the repo root (copy config.example.ps1) and $env:TEAMS_WEBHOOK_URL
  (see src/monitor/test-teams-webhook.ps1).
  WARNING: this posts real cards to a live Teams channel. If another monitor already covers the
  same scope, do not run this in polling mode against it (docs/context.md, "Legacy monitor").
  Requires the `claude` CLI on PATH for the evaluation step.
#>

param(
    [Parameter(Mandatory)][string]$Project,
    [Nullable[int]]$InitialLookbackDays = $null,
    # [string[]] instead of [int[]]: "powershell -File script.ps1 -WorkItemId 1,2,3" passes
    # "1,2,3" as ONE string (no array parsing under -File), which [int[]] cannot bind.
    # Comma splitting is done below so both -File and in-session array calls work.
    [string[]]$WorkItemId = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 talks to native executables (claude) using legacy encodings:
# - stdout of a native command is decoded with [Console]::OutputEncoding, which defaults to
#   the OEM codepage (CP850 on Spanish Windows) -> UTF-8 bytes C3 A1 (a-acute) were decoded
#   as two CP850 box-drawing/accent glyphs (mojibake in the Teams card).
# - text piped INTO a native command is encoded with $OutputEncoding, which defaults to ASCII
#   -> accented characters in the prompt became "?".
# Force UTF-8 both ways. This only shows up under the default console (e.g. Scheduled Task),
# not in terminals already switched to UTF-8.
# Keep this file pure ASCII: PS 5.1 parses BOM-less .ps1 files as Windows-1252.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# The project name builds file paths: allow only lowercase letters, digits and dashes.
# -cnotmatch (case-sensitive) because -notmatch would accept uppercase letters.
if ($Project -cnotmatch '^[a-z0-9-]+$') {
    throw "Invalid -Project '$Project'. Use only lowercase letters, digits and dashes (^[a-z0-9-]+$)."
}
# Copy into a dedicated variable before dot-sourcing config.ps1 / the loader, so nothing they
# define in this scope can shadow the project name.
$ProjectName = $Project

# Repo root is two levels up from src/monitor.
$RepoRoot = (Resolve-Path "$PSScriptRoot/../..").Path

$ConfigPsPath = Join-Path $RepoRoot 'config.ps1'
if (-not (Test-Path $ConfigPsPath)) {
    throw "config.ps1 not found at the repo root. Copy config.example.ps1 to config.ps1 and fill it in (never commit it)."
}
. $ConfigPsPath
. (Join-Path $RepoRoot 'src/lib/ado-powershell/load.ps1')

if (-not $AdoSession) {
    throw "ADO session could not be initialised. Check ADO_ORG/ADO_PROJECT/ADO_PAT in config.ps1."
}
if (-not $env:TEAMS_WEBHOOK_URL) {
    throw "TEAMS_WEBHOOK_URL is not set. Define it in config.ps1 (never hardcode it)."
}

$ConfigPath = Join-Path $RepoRoot "projects/$ProjectName/config.json"
if (-not (Test-Path $ConfigPath)) {
    throw "No se encontro projects/$ProjectName/config.json. Corre src/monitor/setup.ps1 -Project $ProjectName primero."
}
# -Encoding UTF8 is required: PS 5.1 reads BOM-less files as Windows-1252 by default, which
# would mangle accented area paths in config.json or accented text in rubric.md.
$Config = Get-Content -Raw -Encoding UTF8 $ConfigPath | ConvertFrom-Json

$StateDir   = Join-Path $RepoRoot "state/$ProjectName"
$CursorFile = Join-Path $StateDir 'cursor.json'
$AreaPath   = $Config.areaPath
$WorkItemTypes = @($Config.workItemTypes)
if (-not $InitialLookbackDays) {
    $InitialLookbackDays = if ($Config.initialLookbackDays) { [int]$Config.initialLookbackDays } else { 7 }
}

if (-not $AreaPath) { throw "config.json no tiene 'areaPath' definido." }
if ($WorkItemTypes.Count -eq 0) { throw "config.json no tiene 'workItemTypes' definido." }

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

#region -- Cursor --

function Get-Cursor {
    if (Test-Path $CursorFile) {
        return (Get-Content $CursorFile -Raw | ConvertFrom-Json).lastCreatedDate
    }
    return (Get-Date).ToUniversalTime().AddDays(-$InitialLookbackDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Set-Cursor([string]$IsoDate) {
    @{ lastCreatedDate = $IsoDate } | ConvertTo-Json | Set-Content -Path $CursorFile -Encoding utf8
}

#endregion

#region -- Acceptance Criteria default-value lookup (per work item type, cached) --

$script:AcDefaultCache = @{}

function Get-AcceptanceCriteriaDefault([string]$WorkItemType) {
    if ($script:AcDefaultCache.ContainsKey($WorkItemType)) {
        return $script:AcDefaultCache[$WorkItemType]
    }
    $uri = "$(Get-AdoBaseUrl $AdoSession.Org)/$($AdoSession.Project)/_apis/wit/workitemtypes/$([uri]::EscapeDataString($WorkItemType))/fields?api-version=7.1"
    $fields = (Invoke-AdoGet -Uri $uri -Headers $AdoSession.Headers).value
    $acField = $fields | Where-Object { $_.referenceName -eq 'Microsoft.VSTS.Common.AcceptanceCriteria' }
    $default = if ($acField) { $acField.defaultValue } else { $null }
    $script:AcDefaultCache[$WorkItemType] = $default
    return $default
}

#endregion

#region -- Helpers --

function ConvertFrom-AdoHtml([string]$Html) {
    if (-not $Html) { return '' }
    $text = $Html -replace '<br\s*/?>', "`n" -replace '</div>|</p>', "`n" -replace '<[^>]+>', ''
    $text = $text -replace '&nbsp;', ' ' -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>'
    return $text.Trim()
}

function Get-AdoFieldValue($Fields, [string]$Name) {
    # Under Set-StrictMode, direct property access on a PSCustomObject throws when the
    # field was never populated (ADO omits unset fields entirely from the API response).
    $prop = $Fields.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-WorkItemUrl([int]$Id) {
    return "https://dev.azure.com/$($AdoSession.Org)/$($AdoSession.Project)/_workitems/edit/$Id"
}

$RubricPath = Join-Path $RepoRoot 'rubric/rubric.md'
if (-not (Test-Path $RubricPath)) {
    throw "No se encontro el archivo de rubrica: $RubricPath"
}
$Rubric = Get-Content -Raw -Encoding UTF8 $RubricPath

function Invoke-ClaudeEvaluation([string]$Title, [string]$Type, [string]$Description, [string]$AcceptanceCriteria) {
    $itemBlock = @"
Tipo declarado: $Type
Titulo: $Title

Description:
$Description

Acceptance Criteria:
$(if ($AcceptanceCriteria) { $AcceptanceCriteria } else { '(vacio / no definido)' })
"@
    $prompt = "$Rubric`n`n---`n`n$itemBlock"
    $result = $prompt | & claude -p 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "claude -p fallo (exit $LASTEXITCODE) para '$Title': $result"
        return $null
    }
    return ($result | Out-String).Trim()
}

function Send-TeamsFinding([int]$Id, [string]$Title, [string]$Type, [string]$Findings) {
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
                        @{ type = 'TextBlock'; text = "[$Type $Id] $Title"; weight = 'Bolder'; wrap = $true },
                        @{ type = 'TextBlock'; text = $Findings; wrap = $true }
                    )
                    actions   = @(
                        @{ type = 'Action.OpenUrl'; title = 'Abrir en ADO'; url = (Get-WorkItemUrl $Id) }
                    )
                }
            }
        )
    }
    # Windows PowerShell 5.1's Invoke-RestMethod encodes a [string] Body using the system's
    # default codepage, not UTF-8 -- accented characters (Spanish titles/descriptions from ADO)
    # get mangled and Teams/Power Automate rejects the request as InvalidRequestContent.
    # Converting to UTF-8 bytes explicitly avoids that.
    $json  = $card | ConvertTo-Json -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Invoke-RestMethod -Method POST -Uri $env:TEAMS_WEBHOOK_URL -Body $bytes -ContentType 'application/json; charset=utf-8'
}

#endregion

#region -- Main --

$rawIds = @($WorkItemId | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($raw in $rawIds) {
    if ($raw -notmatch '^\d+$') { throw "WorkItemId invalido: '$raw' (se esperan IDs numericos separados por coma)" }
}
[int[]]$Ids = @($rawIds | ForEach-Object { [int]$_ })
$Reprocess = $Ids.Count -gt 0

if ($Reprocess) {
    # Explicit IDs: no WIQL, no cursor read/write. Explicit session params avoid the
    # $script:AdoSession default-parameter scope issue (see .NOTES).
    $items = @(Get-AdoWorkItemsBatch -Ids $Ids -Org $AdoSession.Org -Project $AdoSession.Project -ApiV $AdoSession.ApiV -Headers $AdoSession.Headers)
    if ($items.Count -eq 0) {
        Write-Warning "No se encontro ninguno de los work items pedidos: $($Ids -join ', ')"
        return
    }
    Write-Host "(info) Reprocesando $($items.Count) work item(s): $($Ids -join ', ') -- el cursor no se modifica" -ForegroundColor Cyan
    $cursor = $null
} else {
    $cursor = Get-Cursor
    $cursorDateTime = [datetime]$cursor

    # WIQL only accepts date literals at day granularity (a literal with a non-midnight
    # time-of-day, e.g. '2025-01-24T13:04:31Z', returns 400 Bad Request). So the WIQL filter
    # uses the cursor's DATE only (wider than needed) and the exact cutoff is re-applied below
    # with a precise .NET DateTime comparison, so no item is missed or re-processed.
    $typesClause = ($WorkItemTypes | ForEach-Object { "'$_'" }) -join ', '
    $query = @"
SELECT [System.Id]
FROM WorkItems
WHERE [System.TeamProject] = '$($AdoSession.Project)'
AND [System.AreaPath] = '$AreaPath'
AND [System.WorkItemType] IN ($typesClause)
AND [System.CreatedDate] >= '$($cursorDateTime.ToString('yyyy-MM-dd'))'
ORDER BY [System.CreatedDate] ASC
"@

    $WiqlTop = 500
    # Wrapped in @() because a function that "return @()"-s an empty array yields $null to the
    # caller when captured in a variable (PowerShell collapses empty pipeline output) -- $null.Count
    # then throws under Set-StrictMode instead of evaluating to 0.
    $candidates = @(Invoke-AdoWiql -Query $query -Top $WiqlTop -Org $AdoSession.Org -Project $AdoSession.Project -ApiV $AdoSession.ApiV -Headers $AdoSession.Headers)
    if ($candidates.Count -eq $WiqlTop) {
        Write-Warning "La consulta WIQL devolvio exactamente el tope ($WiqlTop) -- puede haber items adicionales truncados silenciosamente. Considera correr el poller con mas frecuencia o subir `$WiqlTop."
    }
    $items = @($candidates | Where-Object { [datetime](Get-AdoFieldValue $_.fields 'System.CreatedDate') -gt $cursorDateTime })

    if ($items.Count -eq 0) {
        Write-Host "(info) No hay work items nuevos desde $cursor" -ForegroundColor Cyan
        return
    }

    Write-Host "(info) $($items.Count) work item(s) nuevo(s) detectado(s)" -ForegroundColor Cyan
}

$maxCreatedDate = $cursor
foreach ($item in $items) {
    $id          = $item.id
    $fields      = $item.fields
    $title       = Get-AdoFieldValue $fields 'System.Title'
    $type        = Get-AdoFieldValue $fields 'System.WorkItemType'
    $createdDate = Get-AdoFieldValue $fields 'System.CreatedDate'
    $description = ConvertFrom-AdoHtml (Get-AdoFieldValue $fields 'System.Description')
    $acRaw       = Get-AdoFieldValue $fields 'Microsoft.VSTS.Common.AcceptanceCriteria'
    $acDefault   = Get-AcceptanceCriteriaDefault $type

    $acEffective = if (-not $acRaw) {
        $null
    } elseif ($acDefault -and ($acRaw.Trim() -eq $acDefault.Trim())) {
        $null
    } else {
        ConvertFrom-AdoHtml $acRaw
    }

    try {
        $findings = Invoke-ClaudeEvaluation -Title $title -Type $type -Description $description -AcceptanceCriteria $acEffective
        if ($findings) {
            Send-TeamsFinding -Id $id -Title $title -Type $type -Findings $findings
            Write-Host "(ok) #$id evaluado y notificado" -ForegroundColor Green
        } else {
            Write-Warning "#$id sin hallazgos (evaluacion fallida) -- no se notifico"
        }
    } catch {
        Write-Warning "Error procesando #$id ('$title'): $_"
    }

    # Persist the cursor after every item (not just at the end) so a crash or interruption
    # mid-run does not cause already-processed items to be re-evaluated and re-notified.
    if (-not $Reprocess -and $createdDate -gt $maxCreatedDate) {
        $maxCreatedDate = $createdDate
        Set-Cursor $maxCreatedDate
    }
}

if (-not $Reprocess) {
    Write-Host "(ok) Cursor final: $maxCreatedDate" -ForegroundColor Green
}

#endregion
