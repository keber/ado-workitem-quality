<#
.SYNOPSIS
  Interactive setup for the ADO work item quality monitor. Run this once per project
  (one projects/<name>/config.json per monitored ADO project/area). Safe to re-run -- it only
  overwrites the settings you re-enter.

.USAGE
  powershell -NoProfile -ExecutionPolicy Bypass -File src/monitor/setup.ps1 -Project <name>

.PARAMETER Project
  Mandatory. Project name (lowercase letters, digits and dashes only, it builds file paths).
  Writes projects/<name>/config.json.

.NOTES
  Prerequisites this script assumes are already true:
  - config.ps1 exists at the repo root with ADO_ORG / ADO_PROJECT / ADO_PAT (copy
    config.example.ps1). This script APPENDS to it, it does not create ADO credentials from
    scratch -- if config.ps1 does not exist yet, this script tells you what to add manually.
  - The `claude` CLI is on PATH.
  WARNING: the optional steps at the end run the poller (posts real Teams cards) and register
  a Scheduled Task. While the legacy monitor is active, answer "n" to both for any scope it
  already covers (see docs/context.md, "Legacy monitor").
#>

param(
    [Parameter(Mandatory)][string]$Project
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The project name builds file paths: allow only lowercase letters, digits and dashes.
# -cnotmatch (case-sensitive) because -notmatch would accept uppercase letters.
if ($Project -cnotmatch '^[a-z0-9-]+$') {
    throw "Invalid -Project '$Project'. Use only lowercase letters, digits and dashes (^[a-z0-9-]+$)."
}
$ProjectName = $Project

# Repo root is two levels up from src/monitor.
$RepoRoot       = (Resolve-Path "$PSScriptRoot/../..").Path
$ConfigPsPath   = Join-Path $RepoRoot 'config.ps1'
$ProjectDir     = Join-Path $RepoRoot "projects/$ProjectName"
$ConfigJsonPath = Join-Path $ProjectDir 'config.json'

Write-Host "=== Setup del monitor de calidad de work items ADO (proyecto: $ProjectName) ===" -ForegroundColor Cyan
Write-Host ""

#region -- 1. ADO credentials (config.ps1) --

if (-not (Test-Path $ConfigPsPath)) {
    Write-Warning "No existe config.ps1 en la raiz del repo. Copia config.example.ps1 a config.ps1, completa estas variables y vuelve a correr setup.ps1:`n`n`$env:ADO_ORG  = '<tu-org>'`n`$env:ADO_PROJECT = '<tu-proyecto>'`n`$env:ADO_PAT = '<tu-PAT>'   # nunca lo subas a git`n"
    exit 1
}

. $ConfigPsPath
if (-not $env:ADO_ORG -or -not $env:ADO_PROJECT -or -not $env:ADO_PAT) {
    Write-Warning "config.ps1 existe pero falta ADO_ORG, ADO_PROJECT o ADO_PAT. Completalo y vuelve a correr este script."
    exit 1
}
Write-Host "(ok) Credenciales ADO encontradas en config.ps1 (Org: $env:ADO_ORG, Project: $env:ADO_PROJECT)" -ForegroundColor Green

#endregion

#region -- 2. Area path + tipos de work item + lookback (projects/<name>/config.json) --

Write-Host ""
Write-Host "--- Alcance a monitorear ---" -ForegroundColor Cyan
$defaultAreaPath = "$env:ADO_PROJECT"
$areaPath = Read-Host "Area path a monitorear (ej. $env:ADO_PROJECT\NombreDelEquipo) [$defaultAreaPath]"
if (-not $areaPath) { $areaPath = $defaultAreaPath }

$typesInput = Read-Host "Tipos de work item a evaluar, separados por coma [User Story, Task]"
$workItemTypes = if ($typesInput) { $typesInput -split ',' | ForEach-Object { $_.Trim() } } else { @('User Story', 'Task') }

$lookbackInput = Read-Host "Dias hacia atras a revisar en la primera corrida [7]"
$lookbackDays = if ($lookbackInput) { [int]$lookbackInput } else { 7 }

$configObj = [ordered]@{
    areaPath            = $areaPath
    workItemTypes       = @($workItemTypes)
    initialLookbackDays = $lookbackDays
}
New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
$configObj | ConvertTo-Json | Set-Content -Path $ConfigJsonPath -Encoding utf8
Write-Host "(ok) projects/$ProjectName/config.json escrito" -ForegroundColor Green

#endregion

#region -- 3. Teams webhook (config.ps1) --

Write-Host ""
Write-Host "--- Notificacion a Teams ---" -ForegroundColor Cyan
if ($env:TEAMS_WEBHOOK_URL) {
    Write-Host "(ok) TEAMS_WEBHOOK_URL ya esta definido en config.ps1 -- se mantiene el actual." -ForegroundColor Green
} else {
    Write-Host "Necesitas un webhook de Power Automate ('Workflows' en Teams, plantilla 'Post to a"
    Write-Host "channel when a webhook request is received'). Si todavia no lo creaste, pausa aca,"
    Write-Host "crealo en Teams y vuelve a correr este script cuando tengas la URL."
    $webhook = Read-Host "URL del webhook de Teams (dejar vacio para saltar por ahora)"
    if ($webhook) {
        Add-Content -Path $ConfigPsPath -Value "`n`$env:TEAMS_WEBHOOK_URL = '$webhook'   # nunca lo subas a git"
        Write-Host "(ok) TEAMS_WEBHOOK_URL agregado a config.ps1" -ForegroundColor Green
    } else {
        Write-Warning "Sin TEAMS_WEBHOOK_URL el monitor no va a poder notificar. Agregalo despues a config.ps1."
    }
}

#endregion

#region -- 4. Prueba de conexion ADO --

Write-Host ""
Write-Host "--- Verificando conexion a ADO ---" -ForegroundColor Cyan
. (Join-Path $RepoRoot 'src/lib/ado-powershell/load.ps1')
if ($AdoSession) {
    Write-Host "(ok) Sesion ADO inicializada correctamente" -ForegroundColor Green
} else {
    Write-Warning "No se pudo inicializar la sesion ADO. Revisa ADO_ORG/ADO_PROJECT/ADO_PAT en config.ps1."
}

#endregion

#region -- 5. Rubrica --

Write-Host ""
$rubricPath = Join-Path $RepoRoot 'rubric/rubric.md'
Write-Host "--- Rubrica de evaluacion ---" -ForegroundColor Cyan
Write-Host "La rubrica que usa 'claude -p' para evaluar cada work item vive en:"
Write-Host "  $rubricPath"
Write-Host "Es texto plano editable -- revisala y ajustala a los criterios de tu equipo antes de"
Write-Host "activar el monitor en produccion."

#endregion

#region -- 6. Prueba manual + Scheduled Task --

Write-Host ""
Write-Warning "Los dos pasos siguientes publican cards reales en Teams y registran un Scheduled Task. Mientras el monitor legacy siga activo, responde 'n' para cualquier alcance que ya cubra (ver docs/context.md)."
$runNow = Read-Host "Correr una prueba manual ahora? (s/n) [n]"
if ($runNow -eq 's') {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'src/monitor/poll-and-evaluate.ps1') -Project $ProjectName
}

Write-Host ""
$registerTask = Read-Host "Registrar el Scheduled Task de Windows para que corra solo cada 30 min? (s/n) [n]"
if ($registerTask -eq 's') {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'src/monitor/register-scheduled-task.ps1') -Project $ProjectName
}

Write-Host ""
Write-Host "=== Setup completo ===" -ForegroundColor Cyan
