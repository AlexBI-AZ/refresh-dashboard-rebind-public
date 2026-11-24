# Runs a chained Power BI refresh with before/after data validation and one
# combined email, for any report that has a config in the reports folder.
# The refresh itself is the repository's shared runner (runtime\Invoke-RefreshRun.ps1),
# the same code the Control Panel and the Claude skill use; this script adds the
# validation stage around it.
# ASCII only so Windows PowerShell 5.1 reads it correctly.
#
# Exit code: 0 when the run completed and the refresh succeeded; 1 when the run
# stopped early, the refresh failed, or a live email could not be sent.
# Validation verdicts (PASS/WARN/FAIL) are reported, not turned into exit codes.

[CmdletBinding()]
param(
    # Report config name in the reports folder, for example sales-dashboard.
    [string]$Report,
    [string]$ConfigPath,
    [string[]]$Recipients,
    [switch]$SkipRefresh,
    [switch]$PreviewEmail,
    # Compare with a previous usable run instead of this run's own pre-check.
    [int]$BaselineRunsBack = 0,
    # Kept for compatibility: the pre-check is already the default baseline.
    [switch]$BaselineCurrent,
    [switch]$ContinueOnPrecheckError,
    # Upstream dataflows to leave alone, by exact name; passed to the refresh
    # script. Excluding all of them refreshes only the semantic model.
    [string[]]$ExcludeDataflow,
    [string]$ArtifactsRoot,
    [string]$SkillRoot,
    [string]$ProjectRoot,
    # Test seams: a stand-in refresh script and the folder where it writes runs.
    [string]$RefreshScriptPath,
    [string]$ChainRunsRoot
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "validation.ps1")
$ConfigPath = Resolve-ValidationConfigPath -ToolRoot $PSScriptRoot -ConfigPath $ConfigPath -Report $Report

$config = Read-ValidationConfig -Path $ConfigPath

$recipientSource = @($Recipients)
if (@($recipientSource | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) {
    $recipientSource = @($config.recipients)
}
$recipientList = @()
foreach ($value in @($recipientSource)) {
    if ($null -eq $value) { continue }
    foreach ($part in ([string]$value -split '[,;]')) {
        $address = $part.Trim()
        if ($address) { $recipientList += $address }
    }
}
$recipientList = @($recipientList | Select-Object -Unique)

# Sign-in and the refresh come from runtime\ in this repository (the folder above this
# one). -SkillRoot is kept only to run against an installed skill copy on purpose; the
# POWERBI_REFRESH_SKILL_ROOT variable is no longer read, so a stale personal skill copy
# cannot be picked up by accident.
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SkillRoot)) {
    $authModule = Join-Path $repoRoot "runtime\powerbi-auth.ps1"
    $defaultRefreshScript = Join-Path $repoRoot "runtime\Invoke-RefreshRun.ps1"
} else {
    $authModule = Join-Path $SkillRoot "scripts\powerbi-auth.ps1"
    $defaultRefreshScript = Join-Path $SkillRoot "scripts\invoke-refresh-report.ps1"
}
$refreshScript = if ([string]::IsNullOrWhiteSpace($RefreshScriptPath)) { $defaultRefreshScript } else { $RefreshScriptPath }
if (-not (Test-Path -LiteralPath $authModule)) { throw "Auth module not found: $authModule" }
if (-not (Test-Path -LiteralPath $refreshScript)) { throw "Refresh script not found: $refreshScript" }
if ([string]::IsNullOrWhiteSpace($ChainRunsRoot)) {
    $ChainRunsRoot = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "PowerBIChainedRefresh\runs"
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot) -and (Test-Path -LiteralPath (Join-Path $repoRoot "refresh-email.ps1"))) { $ProjectRoot = $repoRoot }
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Get-ValidationConfigValue "POWERBI_REFRESH_PROJECT_ROOT" }
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { throw "Set POWERBI_REFRESH_PROJECT_ROOT or pass -ProjectRoot." }
$emailModulePath = Join-Path $ProjectRoot "refresh-email.ps1"
if (-not (Test-Path -LiteralPath $emailModulePath)) { throw "Email module not found: $emailModulePath" }

$reportKey = Get-ValidationReportKey -WorkspaceName $config.workspaceName -ReportName $config.reportName
$resolvedArtifactsRoot = Resolve-ValidationArtifactsRoot -ConfigRoot $PSScriptRoot -Setting ([string]$config.artifactsRoot) -Override $ArtifactsRoot
$validationRoot = Join-Path $resolvedArtifactsRoot $reportKey
$validationRunsRoot = Join-Path $validationRoot "runs"
New-Item -ItemType Directory -Path $validationRunsRoot -Force | Out-Null
$runName = (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + [Guid]::NewGuid().ToString("N")
$runRoot = Join-Path $validationRunsRoot $runName
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$script:logFile = Join-Path $runRoot "validation-log.txt"
$summaryPath = Join-Path $runRoot "validation-summary.json"
$lockPath = Join-Path $validationRoot "run.lock"

function Write-RunLog {
    param([string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Message"
    Write-Host $line
    try { [System.IO.File]::AppendAllText($script:logFile, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false))) } catch { }
}

function Save-JsonFile {
    param([string]$Path, [object]$Value)
    [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
}

function Update-RunHeaders {
    # App-only tokens last about an hour and a chained refresh takes hours, so a
    # fresh token is taken before each phase that talks to Power BI.
    param([string]$Reason)
    $token = Get-PowerBiAccessToken -Context $script:authContext -ForceRefresh
    $script:headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
    Write-RunLog "Power BI authorization acquired ($Reason)."
}

$script:authContext = $null
$script:headers = $null
$startedAt = Get-Date
$phase = "start"
$fatalError = ""
$lockHeld = $false
$target = $null
$before = $null
$after = $null
$compare = $null
$refreshAttempted = $false
$refreshSummary = $null
$chainRunFolder = $null
$refreshExitCode = $null
$precheckErrorCount = 0
$postcheckErrorCount = 0
$baselineNote = "this run's pre-refresh snapshot"
$baselineMode = "current"
$baselineRunFolder = ""
$emailStatus = "NotAttempted"
$emailWarning = ""
$emailFile = ""

try {
    Write-RunLog "Validation run started. Config: $ConfigPath"
    Write-RunLog "Report key: $reportKey"
    Write-RunLog "Artifacts: $runRoot"

    if (-not $SkipRefresh) {
        $phase = "lock"
        Enter-ValidationLock -Path $lockPath -RunFolder $runRoot
        $lockHeld = $true

        # Fail fast: a multi-hour refresh whose result cannot be delivered is wasted.
        if (-not $PreviewEmail) {
            if ($recipientList.Count -eq 0) {
                Write-RunLog "WARNING: no recipients configured; the result is written to the run folder only."
            } elseif ([string]::IsNullOrWhiteSpace((Get-ValidationConfigValue "REFRESH_EMAIL_WEBHOOK_URL"))) {
                throw "REFRESH_EMAIL_WEBHOOK_URL is not set, so the result could not be emailed. Nothing was refreshed."
            }
        }
    }

    $phase = "authentication"
    . $authModule
    $script:authContext = New-PowerBiAuthContext
    Update-RunHeaders "start"

    $phase = "discovery"
    $target = Resolve-ValidationTarget -WorkspaceName $config.workspaceName -ReportName $config.reportName -Headers $script:headers
    Write-RunLog "Target: workspace '$($target.workspaceName)', report '$($target.reportName)'."
    if (-not $SkipRefresh -and (Test-ValidationRefreshInProgress -Target $target -Headers $script:headers)) {
        throw "A refresh of this semantic model is already running in the Power BI service. Nothing was started."
    }

    $phase = "pre-check"
    Write-RunLog "Running pre-refresh validation."
    $before = Get-ValidationSnapshot -Config $config -Target $target -Headers $script:headers
    Save-JsonFile (Join-Path $runRoot "before.json") $before
    $beforeErrors = @($before.checks | Where-Object { $_.status -eq "Error" })
    $precheckErrorCount = $beforeErrors.Count
    Write-RunLog "Pre-refresh snapshot saved. Checks: $(@($before.checks).Count), errors: $precheckErrorCount."
    foreach ($item in $beforeErrors) { Write-RunLog "Pre-check '$($item.id)' failed to run: $(Get-ValidationSafeText $item.error)" }

    if ($SkipRefresh) {
        Write-RunLog "SkipRefresh set. Stopping after the pre-check."
        $phase = "done"
    } else {
        if ($precheckErrorCount -gt 0 -and -not $ContinueOnPrecheckError) {
            throw "The pre-check could not run $precheckErrorCount check(s), so the refresh was not started. Fix the queries or access, or pass -ContinueOnPrecheckError."
        }

        $phase = "baseline"
        $comparisonBase = $before
        if ($BaselineRunsBack -gt 0) {
            $baseline = Resolve-ValidationBaseline -RunsRoot $validationRunsRoot -RunsBack $BaselineRunsBack -ExcludeRunFolder $runRoot -WorkspaceName $config.workspaceName -ReportName $config.reportName
            $comparisonBase = Get-Content -LiteralPath (Join-Path $baseline.Folder.FullName "after.json") -Raw | ConvertFrom-Json
            $baselineRunFolder = $baseline.Folder.FullName
            $baselineMode = "previous-$BaselineRunsBack-back"
            $baselineNote = "previous usable run $($baseline.Folder.Name) ($BaselineRunsBack back)"
            Save-JsonFile (Join-Path $runRoot "baseline.json") $comparisonBase
        }
        Write-RunLog "Comparison baseline: $baselineNote."

        $phase = "refresh"
        $existingRuns = @(if (Test-Path -LiteralPath $ChainRunsRoot) { Get-ChildItem -LiteralPath $ChainRunsRoot -Directory | ForEach-Object { $_.Name } })
        $childArguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $refreshScript,
            "-WorkspaceName", [string]$config.workspaceName, "-ReportName", [string]$config.reportName,
            "-ProjectRoot", $ProjectRoot, "-Confirmed")
        # This script runs its own validation (with history and earlier-run baselines),
        # so the shared runner skips its built-in one. A skill copy chosen on purpose
        # with -SkillRoot has no such switch and no validation of its own.
        if ([string]::IsNullOrWhiteSpace($SkillRoot) -and [string]::IsNullOrWhiteSpace($RefreshScriptPath)) { $childArguments += "-NoValidation" }
        # powershell.exe -File binds a [string[]] only once, so the names travel as
        # one comma-separated argument; the refresh script splits them again.
        $excludedText = @(@($ExcludeDataflow) | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ","
        if ($excludedText) {
            $childArguments += @("-ExcludeDataflow", $excludedText)
            Write-RunLog "Dataflows excluded from the refresh: $excludedText."
        }
        Write-RunLog "Starting the chained refresh (no email from the refresh script)."
        $refreshAttempted = $true
        # Windows PowerShell 5.1 turns a child's stderr line into a terminating
        # error when the preference is Stop and stderr is redirected. The child
        # throws on a failed refresh, so the call runs under Continue and its
        # stderr is logged like any other line.
        $savedPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & powershell.exe @childArguments 2>&1 | ForEach-Object { Write-RunLog ([string]$_) }
            $refreshExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedPreference
        }
        Write-RunLog "Refresh script exited with code $refreshExitCode."

        $chainRun = Find-ValidationChainRun -RunsRoot $ChainRunsRoot -ExistingNames $existingRuns -WorkspaceName $config.workspaceName -ReportName $config.reportName
        if ($null -eq $chainRun) {
            Write-RunLog "WARNING: no chained run folder for this report was found."
        } else {
            $chainRunFolder = $chainRun.Folder
            $refreshSummary = $chainRun.Summary
            if ($null -eq $refreshSummary) { Write-RunLog "WARNING: the chained run wrote no summary.json: $chainRunFolder" }
            else { Write-RunLog "Refresh summary: $($refreshSummary.Result)." }
        }

        $phase = "post-check"
        Update-RunHeaders "post-check"
        Write-RunLog "Running post-refresh validation."
        $after = Get-ValidationSnapshot -Config $config -Target $target -Headers $script:headers
        Save-JsonFile (Join-Path $runRoot "after.json") $after
        $postcheckErrorCount = @($after.checks | Where-Object { $_.status -eq "Error" }).Count
        Write-RunLog "Post-refresh snapshot saved. Checks: $(@($after.checks).Count), errors: $postcheckErrorCount."

        $phase = "compare"
        $compare = Compare-ValidationSnapshots -Before $comparisonBase -After $after -Config $config
        Save-JsonFile (Join-Path $runRoot "compare.json") $compare
        Write-RunLog "Comparison: overall $($compare.overall) ($($compare.counts.pass) passed, $($compare.counts.warn) warned, $($compare.counts.fail) failed, $($compare.counts.info) informational)."
        $historyPath = Join-Path $validationRoot "history.csv"
        Add-ValidationHistory -Path $historyPath -Compare $compare -RunFolder ("runs\" + $runName) -WorkspaceName $config.workspaceName -ReportName $config.reportName
        Write-RunLog "History updated: $historyPath"
        $phase = "done"
    }
} catch {
    $fatalError = Get-ValidationSafeText $_
    Write-RunLog "ERROR in phase '$phase': $fatalError"
} finally {
    $endedAt = Get-Date
    $refreshResult = if ($null -ne $refreshSummary) { [string]$refreshSummary.Result } elseif ($refreshAttempted) { "Unknown" } else { "NotStarted" }

    if (-not $SkipRefresh) {
        # Every non-preview run reports, including one that stopped early.
        try {
            $emailCompare = $compare
            if ($null -eq $emailCompare) {
                $emailCompare = [pscustomobject][ordered]@{
                    overall = "FAIL"
                    counts = [pscustomobject][ordered]@{ total = 0; pass = 0; warn = 0; fail = 0; info = 0 }
                    checks = @()
                }
            }
            $emailStart = if ($null -ne $refreshSummary -and -not [string]::IsNullOrWhiteSpace([string]$refreshSummary.StartedAt)) { [datetime]$refreshSummary.StartedAt } else { $startedAt }
            $content = New-ValidationEmailContent -Compare $emailCompare -Config $config -RefreshSummary $refreshSummary -RunFolder $runRoot -StartedAt $emailStart -EndedAt $endedAt -BaselineNote $baselineNote -FatalError $fatalError

            # The rendered email is always kept, so a failed send loses nothing.
            $emailFile = Join-Path $runRoot $(if ($PreviewEmail) { "email-preview.html" } else { "email.html" })
            [System.IO.File]::WriteAllText($emailFile, $content.HtmlBody, (New-Object System.Text.UTF8Encoding($false)))

            if ($PreviewEmail) {
                $emailStatus = "Preview"
                Write-RunLog "Preview email written: $emailFile"
            } elseif ($recipientList.Count -eq 0) {
                $emailStatus = "Skipped"
                $emailWarning = "No recipients configured."
                Write-RunLog "No recipients configured; email skipped. Rendered email: $emailFile"
            } else {
                $webhookUrl = Get-ValidationConfigValue "REFRESH_EMAIL_WEBHOOK_URL"
                if ([string]::IsNullOrWhiteSpace($webhookUrl)) {
                    $emailStatus = "Failed"
                    $emailWarning = "REFRESH_EMAIL_WEBHOOK_URL is not set."
                } else {
                    . $emailModulePath
                    try {
                        $sent = Send-RefreshEmail -WebhookUrl $webhookUrl -Recipients $recipientList -Subject $content.Subject -HtmlBody $content.HtmlBody -GetAccessToken {
                            if ($null -eq $script:authContext) { $script:authContext = New-PowerBiAuthContext }
                            Get-RefreshFlowAccessToken -Context $script:authContext
                        }
                        $emailStatus = "Sent"
                        if ($sent -and $sent.SignedIn) { Write-RunLog "The flow only accepts signed-in callers; the email was sent with a Power Automate token." }
                        Write-RunLog "Email submitted for $($recipientList.Count) recipient(s)."
                    } catch {
                        $emailStatus = "Failed"
                        $emailWarning = Get-ValidationSafeText $_
                    }
                }
                if ($emailStatus -eq "Failed") { Write-RunLog "WARNING: email failed: $emailWarning Rendered email: $emailFile" }
            }
        } catch {
            $emailStatus = "Failed"
            $emailWarning = "The email could not be prepared: $(Get-ValidationSafeText $_)"
            Write-RunLog "WARNING: $emailWarning"
        }
    }

    $summary = [pscustomobject][ordered]@{
        workspaceName = [string]$config.workspaceName
        reportName = [string]$config.reportName
        configPath = $ConfigPath
        mode =if ($SkipRefresh) { "pre-check-only" } elseif ($PreviewEmail) { "preview" } else { "live" }
        phase = $phase
        fatalError = $fatalError
        validationResult = if ($null -ne $compare) { [string]$compare.overall } else { "" }
        counts = if ($null -ne $compare) { $compare.counts } else { $null }
        precheckErrors = $precheckErrorCount
        postcheckErrors = $postcheckErrorCount
        refreshAttempted = $refreshAttempted
        refreshResult = $refreshResult
        refreshRunFolder = $chainRunFolder
        excludedDataflows = if ($null -ne $refreshSummary -and $null -ne $refreshSummary.ExcludedDataflows) { @($refreshSummary.ExcludedDataflows) } else { @() }
        chainedRunExitCode = $refreshExitCode
        reportKey = $reportKey
        validationRoot = $validationRoot
        baselineMode = $baselineMode
        baselineRunsBack = $BaselineRunsBack
        baselineRunFolder = $baselineRunFolder
        baselineNote = $baselineNote
        emailStatus = $emailStatus
        emailWarning = $emailWarning
        emailFile = $emailFile
        recipients = @($recipientList)
        startedAt = $startedAt.ToString("o")
        endedAt = $endedAt.ToString("o")
        artifacts = $runRoot
    }
    try { Save-JsonFile $summaryPath $summary } catch { Write-RunLog "WARNING: the summary could not be written: $(Get-ValidationSafeText $_)" }
    if ($lockHeld) { Exit-ValidationLock -Path $lockPath }
    Write-RunLog "Validation run finished (phase '$phase')."
}

$summary | Format-List
$failed = $fatalError -or ($refreshAttempted -and $refreshResult -ne "Succeeded") -or $emailStatus -eq "Failed"
if ($failed) { exit 1 }
exit 0
