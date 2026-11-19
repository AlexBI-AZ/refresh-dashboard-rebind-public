<#
.SYNOPSIS
Refreshes Power BI dataflows and then their semantic models, and reports the result.

.DESCRIPTION
The single refresh runner shared by the Control Panel and the Claude skill
powerbi-chained-refresh. Two ways to say what to refresh:

  -WorkspaceName and -ReportName  the report's semantic model and its upstream
                                  dataflows are found through lineage.
  -PlanBase64                     a Control Panel profile: base64 of a JSON object
                                  {WorkspaceId, DataflowIds[], SemanticModels[{WorkspaceId, DatasetId}]}.

Without -Confirmed it only prints the plan. With -Confirmed it takes a read-only
validation snapshot of each semantic model, refreshes, takes a second snapshot and
compares them (the report config in ..\validation\reports when one matches the model,
otherwise the universal checks), writes refresh-log.txt, summary.json, the snapshots and
the rendered email.html into a new run folder (default
%LOCALAPPDATA%\PowerBIChainedRefresh\runs), sends that email when recipients are given,
and exits 1 when the refresh did not fully succeed. -StatusFile keeps the Control
Panel's live refresh-status.json up to date. -NoValidation skips the validation stage;
only the validated refresh, which runs its own, uses it.

A token from the caller's own sign-in may be passed in the process environment
variable POWERBI_REFRESH_INITIAL_TOKEN (never on the command line or on disk); it is
read once and removed. Otherwise the runner signs in through powerbi-auth.ps1.

Lists (-Recipients, -ExcludeDataflow) may be one comma-separated argument, because
powershell.exe -File binds an array parameter only once.
#>
[CmdletBinding()]
param(
    [string]$WorkspaceName,
    [string]$ReportName,
    [string]$PlanBase64,
    [string[]]$Recipients,
    [string[]]$ExcludeDataflow,
    [string]$ProjectRoot,
    [string]$StatusFile,
    [string]$RunsRoot,
    # A file that receives the error text when the run stops with an error, so a
    # caller that starts this script hidden (the Control Panel) can show why.
    [string]$ErrorLogPath,
    [Alias("DryRun")][switch]$PreviewEmail,
    [switch]$NoValidation,
    [switch]$Confirmed
)

$ErrorActionPreference = "Stop"

# The handed-over token and its sign-in mode are read once and removed from this
# process, so nothing started from here inherits them.
$initialToken = [Environment]::GetEnvironmentVariable("POWERBI_REFRESH_INITIAL_TOKEN", "Process")
$initialMode = [Environment]::GetEnvironmentVariable("POWERBI_REFRESH_INITIAL_TOKEN_MODE", "Process")
[Environment]::SetEnvironmentVariable("POWERBI_REFRESH_INITIAL_TOKEN", $null, "Process")
[Environment]::SetEnvironmentVariable("POWERBI_REFRESH_INITIAL_TOKEN_MODE", $null, "Process")

trap {
    if (-not [string]::IsNullOrWhiteSpace($ErrorLogPath)) {
        try {
            $text = if (Get-Command Get-PowerBiSafeText -ErrorAction SilentlyContinue) { Get-PowerBiSafeText $_ } else { ([string]$_.Exception.Message -replace '[\r\n]+', ' ') }
            [System.IO.File]::AppendAllText($ErrorLogPath, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $text" + [Environment]::NewLine)
        } catch { }
    }
    break
}

. (Join-Path $PSScriptRoot "refresh-engine.ps1")

# refresh-email.ps1 lives in the project root, the folder above runtime\. An explicit
# -ProjectRoot or POWERBI_REFRESH_PROJECT_ROOT still wins, as in the skill.
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = (Get-PowerBiConfigValue "POWERBI_REFRESH_PROJECT_ROOT").Value }
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot -ErrorAction Stop).Path

$plan = $null
if (-not [string]::IsNullOrWhiteSpace($PlanBase64)) {
    try {
        $plan = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PlanBase64)) | ConvertFrom-Json
    } catch {
        throw "The refresh plan could not be read: $(Get-RefreshShortError $_)"
    }
}

$result = Invoke-RefreshRun -WorkspaceName $WorkspaceName -ReportName $ReportName -Plan $plan `
    -ExcludeDataflow $ExcludeDataflow -Recipients $Recipients -PreviewEmail:$PreviewEmail -Confirmed:$Confirmed `
    -StatusFile $StatusFile -RunsRoot $RunsRoot -EmailModulePath (Join-Path $ProjectRoot "refresh-email.ps1") `
    -InitialToken $initialToken -InitialMode $initialMode -NoValidation:$NoValidation
$initialToken = $null

if ($null -eq $result) { return }
$result.Summary | Format-List | Out-Host
if ($result.Failed) { throw "Refresh completed with errors. Review local artifacts at $($result.RunFolder)" }
