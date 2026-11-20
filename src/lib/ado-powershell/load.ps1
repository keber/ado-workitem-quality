# Azure DevOps PowerShell Skill - single-entry loader
# Usage:  . src/lib/ado-powershell/load.ps1
# Dot-sources all skill scripts and auto-initialises the session when ADO_ORG and ADO_PROJECT
# are set. Authentication: Git Credential Manager first, ADO_PAT as fallback (see New-AdoHeaders).

. "$PSScriptRoot/scripts/ado-base.ps1"
. "$PSScriptRoot/scripts/ado-workitems.ps1"
. "$PSScriptRoot/scripts/ado-testing.ps1"
. "$PSScriptRoot/scripts/ado-pipelines.ps1"
. "$PSScriptRoot/scripts/ado-git.ps1"

if ($env:ADO_ORG -and $env:ADO_PROJECT) {
    try {
        $AdoSession = Initialize-AdoSession
        Write-Host "(ok) ADO session ready - Org: $($AdoSession.Org)  Project: $($AdoSession.Project)  Auth: $($AdoSession.AuthSource)" -ForegroundColor Green
    } catch {
        Write-Host "ADO skill loaded but session could not be initialised: $_" -ForegroundColor Yellow
        Write-Host 'Run: $AdoSession = Initialize-AdoSession -Org <org> -Project <project> [-AllowInteractive]' -ForegroundColor Yellow
    }
} else {
    $missing = @('ADO_ORG','ADO_PROJECT') | Where-Object { -not (Get-Item "env:$_" -ErrorAction SilentlyContinue) }
    Write-Host "ADO skill loaded. Missing env vars: $($missing -join ', ')" -ForegroundColor Yellow
    Write-Host 'Run: $AdoSession = Initialize-AdoSession -Org <org> -Project <project>' -ForegroundColor Yellow
}
