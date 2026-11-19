# Offline tests for runtime\refresh-core.ps1. Nothing here signs in or calls the service.
param(
    # Folder holding the skill's scripts, to check that runtime\powerbi-auth.ps1 has
    # not drifted from the skill's copy. Skipped when the skill is not installed.
    [string]$SkillScriptsRoot
)

$ErrorActionPreference = "Stop"

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$runtime = Join-Path $PSScriptRoot "runtime"
. (Join-Path $runtime "refresh-core.ps1")
$checks = 0

# --- dataflow and model status ------------------------------------------------------
Assert ((ConvertTo-DataflowOutcome "Failed") -eq "Failed") "'Failed' must count as a failure"
Assert ((ConvertTo-DataflowOutcome "Failure") -eq "Failed") "'Failure' must count as a failure"
Assert ((ConvertTo-DataflowOutcome "Success") -eq "Succeeded") "'Success' must count as success"
Assert ((ConvertTo-DataflowOutcome "Succeeded") -eq "Succeeded") "'Succeeded' must count as success"
Assert ((ConvertTo-DataflowOutcome "InProgress") -eq "") "A running transaction must not be terminal"
Assert ((ConvertTo-DataflowOutcome $null) -eq "") "A missing status must not be terminal"
$checks++

Assert ((ConvertTo-ModelOutcome ([pscustomobject]@{ status = "Completed" })).Status -eq "Succeeded") "Completed is success"
$failedModel = ConvertTo-ModelOutcome ([pscustomobject]@{ status = "Failed"; serviceExceptionJson = '{"errorCode":"X"}' })
Assert ($failedModel.Status -eq "Failed" -and $failedModel.Error -match "errorCode") "A failed model keeps the service error"
Assert ((ConvertTo-ModelOutcome ([pscustomobject]@{ status = "Failed" })).Error -eq "Power BI reported a failed refresh.") "A failed model without details gets a plain error"
Assert ((ConvertTo-ModelOutcome ([pscustomobject]@{ status = "Disabled" })).Status -eq "Failed") "Disabled is a failure"
Assert ((ConvertTo-ModelOutcome ([pscustomobject]@{ status = "Cancelled" })).Error -eq "Refresh was cancelled.") "Cancelled is a failure"
Assert ((ConvertTo-ModelOutcome ([pscustomobject]@{ status = "Unknown" })).Status -eq "") "The service's Unknown means still running"
Assert ((ConvertTo-ModelOutcome $null).Status -eq "") "No state yet means still running"
$checks++

foreach ($status in @("Succeeded", "Failed", "Unknown")) { Assert (Test-TerminalDataflowStatus $status) "$status ends a dataflow" }
foreach ($status in @("Pending", "Running", "")) { Assert (-not (Test-TerminalDataflowStatus $status)) "$status does not end a dataflow" }
foreach ($status in @("Succeeded", "Failed", "Skipped", "Unknown")) { Assert (Test-TerminalModelStatus $status) "$status ends a model" }
Assert (-not (Test-TerminalModelStatus "Running")) "Running does not end a model"
$checks++

# --- this run's entry -------------------------------------------------------------------
$previousRun = [pscustomobject]@{ startTime = "2026-11-18T10:00:00Z"; status = "Success" }
$thisRun = [pscustomobject]@{ startTime = "2026-11-18T13:41:30Z"; status = "Failed" }
$triggeredAt = "2026-11-18T13:41:27.0000000Z"
Assert ($null -eq (Select-RefreshCurrentEntry -Entries @($previousRun) -TriggeredAt $triggeredAt)) "A previous run must not count as this run"
Assert ((Select-RefreshCurrentEntry -Entries @($previousRun, $thisRun) -TriggeredAt $triggeredAt).status -eq "Failed") "This run is picked over an older one"
Assert ($null -ne (Select-RefreshCurrentEntry -Entries @([pscustomobject]@{ startTime = "2026-11-18T13:41:24Z" }) -TriggeredAt $triggeredAt)) "A few seconds of skew are tolerated"
Assert ($null -eq (Select-RefreshCurrentEntry -Entries @() -TriggeredAt $triggeredAt)) "No entries yet means still waiting"
Assert ((Select-RefreshCurrentEntry -Entries @($previousRun) -TriggeredAt "").status -eq "Success") "Without a trigger time the newest entry is used"
# Model refresh history has no zone designator; it is UTC all the same.
$historyRow = [pscustomobject]@{ startTime = "2026-11-18T13:41:29.15"; status = "Unknown" }
Assert ($null -ne (Select-RefreshCurrentEntry -Entries @($historyRow) -TriggeredAt $triggeredAt)) "An unmarked history time is compared as UTC"
$checks++

# --- time stamps --------------------------------------------------------------------------
Assert ((ConvertTo-RefreshUtcStamp $null) -eq "") "A missing time stays empty"
Assert ((ConvertTo-RefreshUtcStamp "2026-11-10T17:07:31.787Z") -like "2026-11-10T17:07:31*Z") "A Z time keeps its instant"
Assert ((ConvertTo-RefreshUtcStamp "2026-11-10T18:15:12.18") -like "2026-11-10T18:15:12*Z") "An unmarked time gains the UTC designator"
Assert ((ConvertTo-RefreshUtcStamp "not-a-date") -eq "not-a-date") "An unparseable value is kept"
$checks++

# --- text and recipients ------------------------------------------------------------------
$fakeJwt = "eyJ" + ("a" * 10) + "." + ("b" * 10) + "." + ("c" * 10)
Assert ((Get-RefreshShortError "Bearer $fakeJwt failed") -notmatch "eyJ") "Token-shaped text is removed"
Assert ((Get-RefreshShortError ("x" * 400)).Length -le 240) "Error text is capped"
Assert ((Get-RefreshShortError "line one`r`nline two") -eq "line one line two") "Error text is one line"
$recipients = ConvertTo-RefreshRecipientList @(" alice@example.com;BOB@example.com,alice@example.com ")
Assert ($recipients.Count -eq 2) "Recipients are split, trimmed and deduplicated"
$threw = $false
try { ConvertTo-RefreshRecipientList @("Alice <alice@example.com>") | Out-Null } catch { $threw = $true }
Assert $threw "Display names are rejected"
Assert ((ConvertTo-RefreshRecipientList @()).Count -eq 0) "No recipients is an empty list"
$checks++

# --- run folders, lock, JSON -----------------------------------------------------------------
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("refresh-core-tests-" + [Guid]::NewGuid().ToString("N"))
try {
    $runsRoot = Join-Path $sandbox "PowerBIChainedRefresh\runs"
    Assert ((Resolve-RefreshRunsRoot "") -like "*\PowerBIChainedRefresh\runs") "The default runs root is unchanged"
    Assert ((Resolve-RefreshRunsRoot $runsRoot) -eq $runsRoot) "An explicit runs root wins"
    $runFolder = New-RefreshRunFolder -RunsRoot $runsRoot
    Assert ((Split-Path -Leaf $runFolder) -match '^\d{8}-\d{6}-[0-9a-f]{32}$') "Run folders keep the yyyyMMdd-HHmmss-guid name"
    $checks++

    $workspaceId = [Guid]::NewGuid().ToString()
    $datasetId = [Guid]::NewGuid().ToString()
    $lockPath = Get-RefreshLockPath -RunsRoot $runsRoot -WorkspaceId $workspaceId -DatasetId $datasetId
    Assert ($lockPath -eq (Get-RefreshLockPath -RunsRoot $runsRoot -WorkspaceId $workspaceId.ToUpperInvariant() -DatasetId " $datasetId ")) "The lock name ignores case and spaces"
    Assert ($lockPath -notmatch [regex]::Escape($datasetId)) "The lock name does not show the model ID"
    Assert ((Split-Path -Parent (Split-Path -Parent $lockPath)) -eq (Split-Path -Parent $runsRoot)) "Locks live next to the runs folder"

    Enter-RefreshRunLock -Path $lockPath -RunFolder $runFolder
    Assert (Test-Path -LiteralPath $lockPath) "The lock file is created"
    $refused = $false
    try { Enter-RefreshRunLock -Path $lockPath -RunFolder "second" } catch { $refused = $_.Exception.Message -like "*already active*" }
    Assert $refused "A second run for the same model is refused while the owner lives"
    Exit-RefreshRunLock -Path $lockPath
    Assert (-not (Test-Path -LiteralPath $lockPath)) "The owner removes its lock"

    # A lock left by a process that no longer exists is stale and is replaced.
    $stale = [ordered]@{ pid = 999999; processStart = "2000-01-01T00:00:00"; computer = $env:COMPUTERNAME; runFolder = "old"; acquiredAt = "2000-01-01T00:00:00" }
    Write-RefreshJsonFile -Path $lockPath -Value $stale
    Enter-RefreshRunLock -Path $lockPath -RunFolder $runFolder
    Assert (([string](Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json).pid) -eq [string]$PID) "A stale lock is taken over"
    # A lock owned by someone else is never removed by Exit.
    Write-RefreshJsonFile -Path $lockPath -Value $stale
    Exit-RefreshRunLock -Path $lockPath
    Assert (Test-Path -LiteralPath $lockPath) "Exit leaves a lock it does not own"
    $checks++

    $jsonPath = Join-Path $sandbox "value.json"
    Write-RefreshJsonFile -Path $jsonPath -Value ([ordered]@{ name = "x"; list = @(1, 2) })
    $bytes = [System.IO.File]::ReadAllBytes($jsonPath)
    Assert (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) "JSON is written without a byte order mark"
    Assert ((Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json).list.Count -eq 2) "JSON round-trips"
    $checks++
} finally {
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
}

# --- files ----------------------------------------------------------------------------------
foreach ($file in Get-ChildItem -LiteralPath $runtime -Filter *.ps1) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    Assert (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) "$($file.Name) must be ASCII-only"
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) "$($file.Name) must parse"
}
$checks++

if ([string]::IsNullOrWhiteSpace($SkillScriptsRoot)) {
    $skillRoot = [Environment]::GetEnvironmentVariable("POWERBI_REFRESH_SKILL_ROOT", "User")
    if ([string]::IsNullOrWhiteSpace($skillRoot)) { $skillRoot = Join-Path $env:USERPROFILE ".claude\skills\powerbi-chained-refresh" }
    $SkillScriptsRoot = Join-Path $skillRoot "scripts"
}
$skillAuth = Join-Path $SkillScriptsRoot "powerbi-auth.ps1"
if (Test-Path -LiteralPath $skillAuth) {
    # Compared as text with line endings normalised: git may check either copy out with
    # CRLF or LF, and that is not drift. Any other byte difference is.
    $readNormalised = { param([string]$Path) [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($Path)).Replace("`r`n", "`n") }
    foreach ($sharedFile in @("powerbi-auth.ps1", "powerbi-msal-cache.ps1")) {
        $ours = & $readNormalised (Join-Path $runtime $sharedFile)
        $theirs = & $readNormalised (Join-Path $SkillScriptsRoot $sharedFile)
        Assert ($ours -ceq $theirs) "runtime\$sharedFile has drifted from the skill's copy; reconcile them deliberately"
        $checks++
    }
} else {
    Write-Host "SKIPPED: auth drift check (skill scripts not found)" -ForegroundColor Yellow
}

Write-Host "Runtime core tests OK ($checks checks)"
