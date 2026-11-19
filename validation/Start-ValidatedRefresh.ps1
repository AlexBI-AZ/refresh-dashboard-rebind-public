# Starts the validation refresh detached, so a multi-hour run survives the
# terminal. Prints the worker process id and the folder that holds its runs.
# ASCII only so Windows PowerShell 5.1 reads it correctly.

[CmdletBinding()]
param(
    # Report config name in the reports folder, for example sales-dashboard.
    [string]$Report,
    [string]$ConfigPath,
    [string[]]$Recipients,
    [switch]$PreviewEmail,
    [switch]$SkipRefresh,
    [int]$BaselineRunsBack = 0,
    [switch]$BaselineCurrent,
    [switch]$ContinueOnPrecheckError,
    [string[]]$ExcludeDataflow,
    [string]$ArtifactsRoot,
    [string]$SkillRoot,
    [string]$ProjectRoot
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "validation.ps1")
# Resolved here so a wrong report name fails now, not inside the hidden worker.
$ConfigPath = Resolve-ValidationConfigPath -ToolRoot $PSScriptRoot -ConfigPath $ConfigPath -Report $Report
$config = Read-ValidationConfig -Path $ConfigPath
$reportKey = Get-ValidationReportKey -WorkspaceName $config.workspaceName -ReportName $config.reportName
$resolvedArtifactsRoot = Resolve-ValidationArtifactsRoot -ConfigRoot $PSScriptRoot -Setting ([string]$config.artifactsRoot) -Override $ArtifactsRoot
$orchestrator = Join-Path $PSScriptRoot "Invoke-ValidatedRefresh.ps1"
if (-not (Test-Path -LiteralPath $orchestrator)) { throw "Orchestrator not found: $orchestrator" }

# Put the per-user module location first so the worker finds MSAL.PS, as the
# skill's own launcher does, while keeping what this process can already see.
$userModules = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
$modulePaths = @($userModules, "C:\Program Files\WindowsPowerShell\Modules", "C:\Windows\System32\WindowsPowerShell\v1.0\Modules")
if (-not [string]::IsNullOrWhiteSpace($env:PSModulePath)) { $modulePaths += $env:PSModulePath }
$env:PSModulePath = ($modulePaths | Where-Object { $_ } | Select-Object -Unique) -join ';'

function Quote-ProcessArgument {
    param([string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

# powershell.exe -File cannot bind a [string[]] parameter twice, so the
# recipients travel as one comma-separated argument and are split again.
$arguments = "-NoProfile -ExecutionPolicy Bypass -File $(Quote-ProcessArgument $orchestrator) -ConfigPath $(Quote-ProcessArgument $ConfigPath)"
$recipientText = @(@($Recipients) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() }) -join ","
if ($recipientText) { $arguments += " -Recipients $(Quote-ProcessArgument $recipientText)" }
if ($PreviewEmail) { $arguments += " -PreviewEmail" }
if ($SkipRefresh) { $arguments += " -SkipRefresh" }
if ($BaselineRunsBack -gt 0) { $arguments += " -BaselineRunsBack $BaselineRunsBack" }
if ($BaselineCurrent) { $arguments += " -BaselineCurrent" }
if ($ContinueOnPrecheckError) { $arguments += " -ContinueOnPrecheckError" }
$excludeText = @(@($ExcludeDataflow) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() }) -join ","
if ($excludeText) { $arguments += " -ExcludeDataflow $(Quote-ProcessArgument $excludeText)" }
if (-not [string]::IsNullOrWhiteSpace($ArtifactsRoot)) { $arguments += " -ArtifactsRoot $(Quote-ProcessArgument $ArtifactsRoot)" }
if (-not [string]::IsNullOrWhiteSpace($SkillRoot)) { $arguments += " -SkillRoot $(Quote-ProcessArgument $SkillRoot)" }
if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) { $arguments += " -ProjectRoot $(Quote-ProcessArgument $ProjectRoot)" }

$process = Start-Process -FilePath "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -WindowStyle Hidden -PassThru
$runsRoot = Join-Path (Join-Path $resolvedArtifactsRoot $reportKey) "runs"

[pscustomobject][ordered]@{
    Started = (Get-Date).ToString("o")
    ProcessId = $process.Id
    RunsRoot = $runsRoot
    Message = "Validation refresh started in the background. Watch the newest folder under the runs root."
} | Format-List
