<#
.SYNOPSIS
  Registers (or updates) the Windows Scheduled Task that runs poll-and-evaluate.ps1 for one
  project every N minutes under the current user account.

.USAGE
  powershell -NoProfile -ExecutionPolicy Bypass -File src/monitor/register-scheduled-task.ps1 -Project <name> [-IntervalMinutes 30] [-AllowAlongsideLegacy]

.PARAMETER Project
  Mandatory. Project name (lowercase letters, digits and dashes only, it builds file paths).
  The task runs poll-and-evaluate.ps1 -Project <name> and is named ADO-Quality-<name>.

.PARAMETER AllowAlongsideLegacy
  The legacy monitor (Scheduled Task ADO-Monitor-*) posts to the same Teams channel. By
  default this script refuses to register while a legacy task exists, to avoid duplicate
  cards (docs/context.md, "Legacy monitor"). Pass this switch only once the migration has
  been explicitly decided and the scopes do not overlap.

.NOTES
  Runs only when the current user is logged on (no stored password needed).
  Re-running this script updates the existing task in place (idempotent).
  The task name ADO-Quality-<name> is distinct from the legacy task name
  (ADO-Monitor-<repo>-<area>), so both can never collide by name.
#>

param(
    [Parameter(Mandatory)][string]$Project,
    [int]$IntervalMinutes = 30,
    [switch]$AllowAlongsideLegacy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The project name builds file paths and the task name: allow only lowercase letters, digits
# and dashes. -cnotmatch (case-sensitive) because -notmatch would accept uppercase letters.
if ($Project -cnotmatch '^[a-z0-9-]+$') {
    throw "Invalid -Project '$Project'. Use only lowercase letters, digits and dashes (^[a-z0-9-]+$)."
}
$ProjectName = $Project

# Repo root is two levels up from src/monitor.
$RepoRoot   = (Resolve-Path "$PSScriptRoot/../..").Path
$ScriptPath = Join-Path $RepoRoot 'src/monitor/poll-and-evaluate.ps1'
$ConfigPath = Join-Path $RepoRoot "projects/$ProjectName/config.json"

if (-not (Test-Path $ScriptPath)) {
    throw "No se encontro el script a programar: $ScriptPath"
}
if (-not (Test-Path $ConfigPath)) {
    throw "No se encontro projects/$ProjectName/config.json. Corre src/monitor/setup.ps1 -Project $ProjectName primero."
}

$legacyTasks = @(Get-ScheduledTask -TaskName 'ADO-Monitor-*' -ErrorAction SilentlyContinue)
if ($legacyTasks.Count -gt 0 -and -not $AllowAlongsideLegacy) {
    throw "Existe el monitor legacy ($(@($legacyTasks | ForEach-Object { $_.TaskName }) -join ', ')). Registrar otra tarea publicaria cards duplicadas. Ver docs/context.md; usa -AllowAlongsideLegacy solo si la migracion ya esta decidida."
}

$Config   = Get-Content -Raw -Encoding UTF8 $ConfigPath | ConvertFrom-Json
$TaskName = "ADO-Quality-$ProjectName"

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Project $ProjectName" `
    -WorkingDirectory $RepoRoot

# A finite 10-year duration: [TimeSpan]::MaxValue produces invalid task XML.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "(info) Tarea existente '$TaskName' reemplazada" -ForegroundColor Cyan
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description "Monitorea Azure DevOps (proyecto '$ProjectName', area '$($Config.areaPath)') por nuevos User Story/Task, evalua calidad via claude -p y notifica a Teams." | Out-Null

Write-Host "(ok) Scheduled Task '$TaskName' registrado -- corre cada $IntervalMinutes min mientras el usuario este logueado" -ForegroundColor Green
Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State
