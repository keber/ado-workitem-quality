<#
.SYNOPSIS
  Base authentication and HTTP pattern for the Azure DevOps PowerShell Skill.
  Dot-source this file before using ado-workitems.ps1, ado-testing.ps1, ado-pipelines.ps1, or ado-git.ps1.

.USAGE
  . "$PSScriptRoot/ado-base.ps1"

.NOTES
  Authentication: Git Credential Manager first (Entra ID token from the user's sign-in), then
  ADO_PAT as fallback. Never hardcode the PAT in code.
  Variables: ADO_ORG, ADO_PROJECT (required), ADO_PAT (fallback), ADO_AUTH_MODE (Auto|Gcm|Pat).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region -- Authentication --

function Get-AdoGcmToken {
    <#
    .SYNOPSIS  Asks Git Credential Manager (GCM) for an Azure DevOps credential.
    .DESCRIPTION
      Runs "git credential-manager get" for host dev.azure.com and returns the password field.
      With credential.azreposCredentialType=oauth (the GCM default for Azure Repos) this is a
      Microsoft Entra ID access token obtained from the user's sign-in, which satisfies Entra
      conditional access policies that can reject a PAT (VS403463).
      Runs non-interactively by default (GCM_INTERACTIVE=never) with a timeout, so an unattended
      run (Scheduled Task) fails fast instead of waiting for a sign-in window nobody will see.
      The token is never written to output, logs or error messages.
    .PARAMETER Org               ADO organization, sent as the credential path.
    .PARAMETER AllowInteractive  Let GCM show its sign-in UI when no cached credential exists.
    .PARAMETER TimeoutSec        Maximum seconds to wait for GCM (default 20).
    .OUTPUTS   String (the credential). Throws on any failure.
    #>
    param(
        [string]$Org = $env:ADO_ORG,
        [switch]$AllowInteractive,
        [int]$TimeoutSec = 20
    )
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is not installed or not on PATH.' }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'git'
    $psi.Arguments              = 'credential-manager get'
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $psi.EnvironmentVariables['GCM_INTERACTIVE'] = if ($AllowInteractive) { 'auto' } else { 'never' }

    # Started as a process (not piped) on purpose: under Windows PowerShell 5.1 with
    # $ErrorActionPreference = 'Stop', any stderr line of a piped native command terminates the
    # script, and a pipe cannot enforce a timeout.
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $proc.StandardInput.Write("protocol=https`nhost=dev.azure.com`npath=$Org`n`n")
        $proc.StandardInput.Close()
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch { }
            throw "Git Credential Manager did not answer within $TimeoutSec s."
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        if ($proc.ExitCode -ne 0) {
            $reason = ($stderr -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1)
            throw "Git Credential Manager failed (exit $($proc.ExitCode)): $reason"
        }
    } finally {
        $proc.Dispose()
    }

    $tokenLine = $stdout -split "`r?`n" | Where-Object { $_ -match '^password=' } | Select-Object -First 1
    if (-not $tokenLine -or $tokenLine.Length -le 9) { throw 'Git Credential Manager returned no access token.' }
    return $tokenLine.Substring(9)
}

function New-AdoHeaders {
    <#
    .SYNOPSIS  Creates the HTTP Authorization header for ADO REST API.
    .DESCRIPTION
      Auth resolution (AuthMode Auto, the default):
        1. Git Credential Manager (Entra ID token, or a PAT if GCM is configured for PATs)
        2. PAT: -Pat -> $env:ADO_PAT -> $env:AZURE_DEVOPS_EXT_PAT
      AuthMode Gcm or Pat forces one source (env ADO_AUTH_MODE sets the default).
      The source used is recorded in $script:AdoAuthSource (gcm-oauth | gcm-pat | pat); the
      credential itself is never written anywhere.
    .PARAMETER Pat               Azure DevOps PAT (fallback).
    .PARAMETER Org               ADO organization (used for the GCM request).
    .PARAMETER AuthMode          Auto | Gcm | Pat.
    .PARAMETER AllowInteractive  Allow GCM to show a sign-in window (manual runs only).
    .OUTPUTS   Hashtable @{ Authorization = "Bearer <token>" } or @{ Authorization = "Basic <b64>" }
    .NOTES
      Entra ID access tokens expire (about an hour). Headers are built once per session; for
      long runs, rebuild the session (Initialize-AdoSession) if a 401 appears mid-run.
    #>
    param(
        [string]$Pat = '',
        [string]$Org = $env:ADO_ORG,
        [ValidateSet('Auto', 'Gcm', 'Pat')]
        [string]$AuthMode = $(if ($env:ADO_AUTH_MODE) { $env:ADO_AUTH_MODE } else { 'Auto' }),
        [switch]$AllowInteractive
    )

    $gcmError = $null
    if ($AuthMode -in 'Auto', 'Gcm') {
        try {
            $token = Get-AdoGcmToken -Org $Org -AllowInteractive:$AllowInteractive
            # Entra ID access tokens are JWTs (header.payload.signature, header starts "eyJ").
            # Anything else is a PAT handed out by GCM, which ADO only accepts as Basic auth.
            if ($token -match '^eyJ[\w-]*\.[\w-]+\.[\w-]+$') {
                $script:AdoAuthSource = 'gcm-oauth'
                return @{ Authorization = "Bearer $token" }
            }
            $script:AdoAuthSource = 'gcm-pat'
            $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$token"))
            return @{ Authorization = "Basic $b64" }
        } catch {
            $gcmError = $_.Exception.Message
            if ($AuthMode -eq 'Gcm') { throw "Git Credential Manager authentication failed: $gcmError" }
            Write-Verbose "Git Credential Manager unavailable, falling back to PAT: $gcmError"
        }
    }

    if ([string]::IsNullOrWhiteSpace($Pat)) { $Pat = $env:ADO_PAT }
    if ([string]::IsNullOrWhiteSpace($Pat)) { $Pat = $env:AZURE_DEVOPS_EXT_PAT }
    if ([string]::IsNullOrWhiteSpace($Pat)) {
        $why = if ($gcmError) { " Git Credential Manager also failed: $gcmError" } else { '' }
        throw "No ADO credential available. Set ADO_PAT or AZURE_DEVOPS_EXT_PAT, pass -Pat, or sign in through Git Credential Manager.$why"
    }
    $script:AdoAuthSource = 'pat'
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
    return @{ Authorization = "Basic $b64" }
}

#endregion

#region -- HTTP core with retries --

function Invoke-AdoRequest {
    <#
    .SYNOPSIS
      Performs an authenticated HTTP call to ADO REST API with automatic
      retries and exponential backoff.

    .PARAMETER Method       GET | POST | PATCH | PUT | DELETE
    .PARAMETER Uri          Full endpoint URL.
    .PARAMETER Body         Request body (UTF-8 string).
    .PARAMETER ContentType  Content-Type of the body. Default: application/json.
    .PARAMETER Headers      Hashtable of headers. Default: New-AdoHeaders.
    .PARAMETER MaxRetries   Maximum number of attempts (default: 3).
    .PARAMETER RetryDelaySec Base seconds for backoff (default: 2).
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET','POST','PATCH','PUT','DELETE')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [string]$Body,
        [string]$ContentType = 'application/json',
        [hashtable]$Headers,
        [int]$MaxRetries     = 3,
        [int]$RetryDelaySec  = 2
    )

    if (-not $Headers) { $Headers = New-AdoHeaders }

    $attempt = 0
    $lastErr = $null

    while ($attempt -lt $MaxRetries) {
        $attempt++
        try {
            $params = @{
                Method      = $Method
                Uri         = $Uri
                Headers     = $Headers
                ErrorAction = 'Stop'
            }
            if ($Body) {
                $params.Body        = [Text.Encoding]::UTF8.GetBytes($Body)
                $params.ContentType = $ContentType
            }

            $response = Invoke-RestMethod @params

            # Detect HTML response (login page instead of JSON)
            if ($response -is [string] -and $response -match '(?i)<html|sign.?in') {
                throw "Server returned HTML. Check ADO_PAT and the URL: $Uri"
            }
            return $response
        }
        catch {
            $lastErr = $_
            $status  = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }

            # 401 / 403: do not retry. The cause is NOT always the PAT: ADO also returns 403 when an
            # Entra ID conditional access policy fails (VS403463: device, network or sign-in
            # session). ADO names the real cause in the X-TFS-ServiceError header, so surface it
            # instead of guessing.
            if ($status -in 401, 403) {
                $serviceError = $null
                try {
                    $raw = $_.Exception.Response.Headers['X-TFS-ServiceError']
                    if ($raw) { $serviceError = [uri]::UnescapeDataString($raw) }
                } catch { }

                $hint = if ($serviceError -match '^VS403463') {
                    'Entra ID conditional access policy failed: the PAT is probably fine. Sign in again to Azure DevOps / Entra in the browser, or reconnect the network or VPN the policy requires, then retry.'
                } elseif ($status -eq 401) {
                    'Check ADO_PAT: it may be expired, revoked or malformed.'
                } else {
                    'The PAT may lack the required scope, or an organization policy blocked the request.'
                }

                $msg = "$status $(if ($status -eq 401) { 'Unauthorized' } else { 'Forbidden' }) - $Uri"
                if ($serviceError) { $msg += "`nADO service error: $serviceError" }
                $msg += "`n$hint"
                throw $msg
            }

            # 400: bad request - do not retry, include response body for diagnosis
            if ($status -eq 400) {
                $body400 = ''
                try {
                    $stream400 = $_.Exception.Response.GetResponseStream()
                    $reader400 = [System.IO.StreamReader]::new($stream400)
                    $body400   = $reader400.ReadToEnd()
                } catch { }
                throw "400 Bad Request - $Uri`n$body400"
            }

            # 404: do not retry - resource does not exist
            if ($status -eq 404) {
                throw "404 Not Found - resource not found: $Uri"
            }

            # 429 / 503: rate-limit -- exponential backoff
            if ($status -in 429, 503) {
                $waitSec = $RetryDelaySec * [Math]::Pow(2, $attempt)
                Write-Warning "[$status] Rate-limit. Retry $attempt/$MaxRetries in ${waitSec}s..."
                Start-Sleep -Seconds $waitSec
                continue
            }

            # Other transient errors: linear backoff
            if ($attempt -lt $MaxRetries) {
                $waitSec = $RetryDelaySec * $attempt
                Write-Warning "Error (attempt $attempt/$MaxRetries): $($_.Exception.Message). Retrying in ${waitSec}s..."
                Start-Sleep -Seconds $waitSec
            }
        }
    }

    throw "Failed after $MaxRetries attempts. Last error: $($lastErr.Exception.Message)"
}

# -- Convenience alias: GET (read-only, never needs ShouldProcess)
function Invoke-AdoGet {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers,
        [int]$MaxRetries    = 3,
        [int]$RetryDelaySec = 2
    )
    Invoke-AdoRequest -Method GET -Uri $Uri -Headers $Headers `
        -MaxRetries $MaxRetries -RetryDelaySec $RetryDelaySec
}

# -- Authenticated file download: wraps Invoke-WebRequest -OutFile with no business logic
function Invoke-AdoDownload {
    <#
    .SYNOPSIS
      Downloads a resource from an authenticated ADO URL directly to a local file.
    .PARAMETER Uri      Full URL to download (including api-version if required).
    .PARAMETER OutFile  Local path where the file will be saved.
    .PARAMETER Headers  Auth headers (hashtable). Defaults to New-AdoHeaders.
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [hashtable]$Headers
    )
    if (-not $Headers) { $Headers = New-AdoHeaders }
    Invoke-WebRequest -Uri $Uri -Headers $Headers -OutFile $OutFile -ErrorAction Stop
}
#endregion

#region -- Session object --

function Resolve-AdoConfig {
    <#
    .SYNOPSIS
      Resolves connection settings from explicit parameters, environment variables,
      and an optional JSON config file. Returns a plain hashtable - does NOT build
      headers or create the session object.

    .DESCRIPTION
      Resolution order for each value:
        1. Explicit parameter (if non-empty)
        2. Environment variable
        3. Config file (if -ConfigPath is supplied and the file exists)

      PAT resolution order:
        -Pat -> $env:ADO_PAT -> $env:AZURE_DEVOPS_EXT_PAT -> config file

      Config file format (JSON):
        { "org": "", "project": "", "apiVersion": "", "pat": "", "baseUrl": "" }

    .OUTPUTS  Hashtable with keys: Org, Project, ApiV, Pat, BaseUrl
    .EXAMPLE
      $cfg = Resolve-AdoConfig -Org 'contoso' -Project 'MyApp'
    .EXAMPLE
      $cfg = Resolve-AdoConfig -ConfigPath "$HOME/.config/ado-powershell/config.json"
    #>
    param(
        [string]$Org        = '',
        [string]$Project    = '',
        [string]$ApiV       = '',
        [string]$Pat        = '',
        [string]$BaseUrl    = '',
        [string]$ConfigPath = ''
    )

    #    optional config file
    $file = @{}
    if ($ConfigPath -and (Test-Path $ConfigPath)) {
        try {
            $raw  = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            $file = @{
                Org     = if ($raw.org)        { $raw.org        } else { '' }
                Project = if ($raw.project)    { $raw.project    } else { '' }
                ApiV    = if ($raw.apiVersion) { $raw.apiVersion } else { '' }
                Pat     = if ($raw.pat)        { $raw.pat        } else { '' }
                BaseUrl = if ($raw.baseUrl)    { $raw.baseUrl    } else { '' }
            }
        } catch {
            Write-Warning "Resolve-AdoConfig: Could not parse config file '$ConfigPath': $_"
        }
    }

    # Resolve each value: param > env > file
    # Use bracket notation ($file['Key']) - dot notation throws with Set-StrictMode on empty hashtables
    $resolvedOrg  = if ($Org)                        { $Org }
                    elseif ($env:ADO_ORG)            { $env:ADO_ORG }
                    elseif ($file['Org'])            { $file['Org'] }
                    else { '' }

    $resolvedProj = if ($Project)                    { $Project }
                    elseif ($env:ADO_PROJECT)        { $env:ADO_PROJECT }
                    elseif ($file['Project'])        { $file['Project'] }
                    else { '' }

    $resolvedApiV = if ($ApiV)                       { $ApiV }
                    elseif ($env:ADO_API_VER)        { $env:ADO_API_VER }
                    elseif ($file['ApiV'])           { $file['ApiV'] }
                    else { '7.1' }

    $resolvedPat  = if ($Pat)                        { $Pat }
                    elseif ($env:ADO_PAT)            { $env:ADO_PAT }
                    elseif ($env:AZURE_DEVOPS_EXT_PAT) { $env:AZURE_DEVOPS_EXT_PAT }
                    elseif ($file['Pat'])            { $file['Pat'] }
                    else { '' }

    $resolvedBase = if ($BaseUrl)                    { $BaseUrl }
                    elseif ($file['BaseUrl'])        { $file['BaseUrl'] }
                    elseif ($resolvedOrg)            { "https://dev.azure.com/$resolvedOrg" }
                    else { '' }

    # Validate required fields
    $missing = @()
    if (-not $resolvedOrg)  { $missing += 'Org  (param -Org or env ADO_ORG)' }
    if (-not $resolvedProj) { $missing += 'Project  (param -Project or env ADO_PROJECT)' }
    # PAT is optional: New-AdoHeaders tries Git Credential Manager first and only needs the PAT
    # as a fallback (it throws a clear error if neither is available).

    if ($missing.Count -gt 0) {
        throw "Resolve-AdoConfig: Missing required config values:`n  - $($missing -join "`n  - ")"
    }

    return @{
        Org     = $resolvedOrg
        Project = $resolvedProj
        ApiV    = $resolvedApiV
        Pat     = $resolvedPat
        BaseUrl = $resolvedBase
    }
}

function Initialize-AdoSession {
    <#
    .SYNOPSIS
      Initializes the $AdoSession object with org, project, version, base URL, and headers.

    .DESCRIPTION
      Resolution order:
        1) Explicit parameters
        2) Environment variables  (ADO_ORG, ADO_PROJECT, ADO_API_VER)
        3) Optional config file   (-ConfigPath)

      PAT resolution order:
        -Pat -> $env:ADO_PAT -> $env:AZURE_DEVOPS_EXT_PAT -> config file

    .OUTPUTS
      PSCustomObject used by ado-workitems, ado-testing, ado-pipelines, and ado-git
      functions as session defaults.

    .EXAMPLE
      $AdoSession = Initialize-AdoSession

    .EXAMPLE
      $AdoSession = Initialize-AdoSession -Org 'contoso' -Project 'MyApp'

    .EXAMPLE
      $AdoSession = Initialize-AdoSession -ConfigPath "$HOME/.config/ado-powershell/config.json"
    #>
    param(
        [string]$Org        = '',
        [string]$Project    = '',
        [string]$ApiV       = '',
        [string]$Pat        = '',
        [string]$BaseUrl    = '',
        [string]$ConfigPath = '',
        [ValidateSet('Auto', 'Gcm', 'Pat')]
        [string]$AuthMode   = $(if ($env:ADO_AUTH_MODE) { $env:ADO_AUTH_MODE } else { 'Auto' }),
        [switch]$AllowInteractive
    )

    $resolved = Resolve-AdoConfig `
        -Org        $Org `
        -Project    $Project `
        -ApiV       $ApiV `
        -Pat        $Pat `
        -BaseUrl    $BaseUrl `
        -ConfigPath $ConfigPath

    $headers = New-AdoHeaders -Pat $resolved.Pat -Org $resolved.Org -AuthMode $AuthMode -AllowInteractive:$AllowInteractive
    $session = [pscustomobject]@{
        Org        = $resolved.Org
        Project    = $resolved.Project
        ApiV       = $resolved.ApiV
        BaseUrl    = $resolved.BaseUrl
        Headers    = $headers
        AuthSource = $script:AdoAuthSource
    }

    # Export as script variable so domain files can find it
    Set-Variable -Name AdoSession -Value $session -Scope Script -Force
    return $session
}

function Get-AdoBaseUrl {
    <#
    .SYNOPSIS  Returns the base ADO URL for the given org, preferring a custom BaseUrl if set.
    #>
    param([string]$Org = $script:AdoSession.Org)
    # If caller has a custom BaseUrl on the session (e.g. ADO Server), use it.
    if ($Org -eq $script:AdoSession.Org -and $script:AdoSession.BaseUrl) {
        return $script:AdoSession.BaseUrl
    }
    return "https://dev.azure.com/$Org"
}

#endregion
