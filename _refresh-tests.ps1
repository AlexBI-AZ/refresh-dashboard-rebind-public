$ErrorActionPreference = "Stop"

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$serverPath = Join-Path $PSScriptRoot "server.ps1"
$serverSource = Get-Content -LiteralPath $serverPath -Raw
$tokens = $null
$errors = $null
$serverAst = [System.Management.Automation.Language.Parser]::ParseInput($serverSource, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) "server.ps1 must parse"

foreach ($functionName in @("Get-RefreshProfileItems", "Get-UniqueRefreshProfiles", "ConvertTo-JsonArray", "Get-NormalizedRecipients", "Get-RefreshRequest")) {
    $functionAst = $serverAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    Assert ($null -ne $functionAst) "Missing $functionName"
    Invoke-Expression $functionAst.Extent.Text
}

$olderProfile = [pscustomobject]@{ name = "Profile A"; marker = "older" }
$otherProfile = [pscustomobject]@{ name = "Profile B"; marker = "only" }
$newerProfile = [pscustomobject]@{ name = "Profile A"; marker = "newer" }
$nestedProfiles = [pscustomobject]@{
    value = @(
        [pscustomobject]@{ value = @($olderProfile, $otherProfile); Count = 2 },
        $newerProfile
    )
    Count = 2
}
$recoveredProfiles = @(Get-UniqueRefreshProfiles $nestedProfiles)
Assert ($recoveredProfiles.Count -eq 2) "Nested profile wrappers should be flattened"
Assert (($recoveredProfiles | Where-Object { $_.name -eq "Profile A" }).marker -eq "newer") "Latest duplicate profile should win"
$profileJson = ConvertTo-JsonArray $recoveredProfiles
Assert ($profileJson.StartsWith("[") -and $profileJson.EndsWith("]")) "Profiles must serialize as a JSON array"
$roundTripProfiles = $profileJson | ConvertFrom-Json
Assert (@($roundTripProfiles).Count -eq 2) "Serialized profiles should survive a JSON round trip"
$singleProfileJson = ConvertTo-JsonArray @([pscustomobject]@{ name = "Only profile" })
Assert ($singleProfileJson -match '^\[\{.*\}\]$') "A single profile must remain wrapped in a JSON array"

$normalized = Get-NormalizedRecipients " alice@example.com;BOB@example.com,alice@example.com "
Assert $normalized.Ok "Valid recipients should be accepted"
Assert ($normalized.Recipients.Count -eq 2) "Recipients should be trimmed and deduplicated"
Assert (-not (Get-NormalizedRecipients "not-an-email").Ok) "Invalid recipients should be rejected"

$workspaceId = [Guid]::NewGuid().ToString()
$dataflowId = [Guid]::NewGuid().ToString()
$datasetId = [Guid]::NewGuid().ToString()
$legacy = Get-RefreshRequest ([pscustomobject]@{
    WorkspaceId = $workspaceId
    DataflowId = $dataflowId
    DatasetId = $datasetId
    NotifyEmails = "test@example.com"
})
Assert $legacy.Ok "Legacy single-model request should remain valid"
Assert ($legacy.SemanticModels.Count -eq 1) "Legacy DatasetId should become one semantic model"
Assert ($legacy.SemanticModels[0].WorkspaceId -eq $workspaceId) "Legacy semantic model should inherit the dataflow workspace"

$secondWorkspaceId = [Guid]::NewGuid().ToString()
$secondDatasetId = [Guid]::NewGuid().ToString()
$multiple = Get-RefreshRequest ([pscustomobject]@{
    WorkspaceId = $workspaceId
    DataflowIds = @($dataflowId)
    SemanticModels = @(
        [pscustomobject]@{ WorkspaceId = $workspaceId; DatasetId = $datasetId },
        [pscustomobject]@{ WorkspaceId = $secondWorkspaceId; DatasetId = $secondDatasetId }
    )
    NotificationRecipients = @("first@example.com", "first@example.com", "second@example.com")
    EmailDryRun = $true
})
Assert $multiple.Ok "Multiple semantic models should be accepted"
Assert ($multiple.SemanticModels.Count -eq 2) "Both semantic models should be retained"
Assert ($multiple.NotificationRecipients.Count -eq 2) "Duplicate recipient should be removed"
Assert $multiple.EmailDryRun "Dry-run flag should be retained"

# Model only (the Refresh tab's "Model only" box): no dataflows, and the dataflow
# workspace is then optional because each semantic model carries its own.
$modelOnly = Get-RefreshRequest ([pscustomobject]@{
    WorkspaceId = ""
    DataflowIds = @()
    SemanticModels = @([pscustomobject]@{ WorkspaceId = $secondWorkspaceId; DatasetId = $secondDatasetId })
})
Assert $modelOnly.Ok "A model-only request should be accepted: $($modelOnly.Error)"
Assert (@($modelOnly.DataflowIds).Count -eq 0 -and $modelOnly.WorkspaceId -eq "") "A model-only request carries no dataflows and no dataflow workspace"
Assert ($modelOnly.SemanticModels[0].WorkspaceId -eq $secondWorkspaceId) "The model keeps its own workspace"
$modelOnlyWithWorkspace = Get-RefreshRequest ([pscustomobject]@{ WorkspaceId = $workspaceId; SemanticModels = @([pscustomobject]@{ WorkspaceId = $workspaceId; DatasetId = $datasetId }) })
Assert ($modelOnlyWithWorkspace.Ok -and $modelOnlyWithWorkspace.WorkspaceId -eq $workspaceId) "A model-only request may still name its workspace"
$dataflowsWithoutWorkspace = Get-RefreshRequest ([pscustomobject]@{ WorkspaceId = ""; DataflowIds = @($dataflowId); SemanticModels = @([pscustomobject]@{ WorkspaceId = $workspaceId; DatasetId = $datasetId }) })
Assert (-not $dataflowsWithoutWorkspace.Ok) "Dataflows still need their workspace"
Assert (-not (Get-RefreshRequest ([pscustomobject]@{ WorkspaceId = "not-a-guid"; SemanticModels = @([pscustomobject]@{ WorkspaceId = $workspaceId; DatasetId = $datasetId }) })).Ok) "A workspace that is given must be a GUID"
Assert (-not (Get-RefreshRequest ([pscustomobject]@{ WorkspaceId = $workspaceId; DataflowIds = @() })).Ok) "A request with neither dataflows nor models is refused"
Assert (-not (Get-RefreshRequest ([pscustomobject]@{ WorkspaceId = ""; DatasetId = $datasetId })).Ok) "A legacy model without any workspace is refused"

# Dataflows chosen by name may live in other workspaces: Dataflows = [{WorkspaceId, DataflowId}].
$otherDataflowId = [Guid]::NewGuid().ToString()
$crossWorkspace = Get-RefreshRequest ([pscustomobject]@{
    WorkspaceId = $workspaceId
    DataflowIds = @($dataflowId)
    Dataflows = @(
        [pscustomobject]@{ WorkspaceId = $secondWorkspaceId; DataflowId = $otherDataflowId },
        [pscustomobject]@{ DataflowId = $dataflowId },
        [pscustomobject]@{ WorkspaceId = $secondWorkspaceId; DataflowId = $otherDataflowId.ToUpperInvariant() })
    SemanticModels = @([pscustomobject]@{ WorkspaceId = $workspaceId; DatasetId = $datasetId })
})
Assert $crossWorkspace.Ok "Dataflows in another workspace are accepted: $($crossWorkspace.Error)"
Assert (@($crossWorkspace.DataflowIds).Count -eq 1 -and @($crossWorkspace.Dataflows).Count -eq 1) "Duplicates collapse across both forms"
Assert ($crossWorkspace.Dataflows[0].WorkspaceId -eq $secondWorkspaceId -and $crossWorkspace.Dataflows[0].DataflowId -eq $otherDataflowId) "A dataflow keeps its own workspace"
$entriesOnly = Get-RefreshRequest ([pscustomobject]@{ WorkspaceId = ""; Dataflows = @([pscustomobject]@{ WorkspaceId = $secondWorkspaceId; DataflowId = $otherDataflowId }); SemanticModels = @([pscustomobject]@{ WorkspaceId = $workspaceId; DatasetId = $datasetId }) })
Assert ($entriesOnly.Ok -and @($entriesOnly.Dataflows).Count -eq 1) "Dataflows with their own workspace need no request workspace"
Assert (-not (Get-RefreshRequest ([pscustomobject]@{ WorkspaceId = ""; Dataflows = @([pscustomobject]@{ DataflowId = $otherDataflowId }); SemanticModels = @([pscustomobject]@{ WorkspaceId = $workspaceId; DatasetId = $datasetId }) })).Ok) "A dataflow without any workspace is refused"
Assert (-not (Get-RefreshRequest ([pscustomobject]@{ WorkspaceId = $workspaceId; Dataflows = @([pscustomobject]@{ DataflowId = "nope" }); SemanticModels = @([pscustomobject]@{ WorkspaceId = $workspaceId; DatasetId = $datasetId }) })).Ok) "A dataflow ID that is not a GUID is refused"

# One email format for every refresh: refresh-email.ps1 only sends; the email is built by
# New-ValidationEmailContent in validation\validation.ps1 (tested in validation\tests
# and _runner-tests.ps1). The plain builder and the old worker template are gone.
. (Join-Path $PSScriptRoot "refresh-email.ps1")
Assert ($null -ne (Get-Command Send-RefreshEmail -ErrorAction SilentlyContinue)) "refresh-email.ps1 must still send"
Assert ($null -eq (Get-Command Get-RefreshEmailContent -ErrorAction SilentlyContinue)) "The plain refresh email builder must be gone"
Assert (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot "_refresh-worker-template.ps1"))) "The old worker template must be gone"

# The service returns the same instant two ways: dataflow transactions append "Z",
# dataset refresh history omits any designator. The runner normalises every end time to
# an explicit UTC stamp, and the email's Completed column shows it in local time.
. (Join-Path $PSScriptRoot "runtime\refresh-core.ps1")
. (Join-Path $PSScriptRoot "validation\validation.ps1")
Assert ((ConvertTo-RefreshUtcStamp $null) -eq '') "Missing completion time should normalise to empty"
Assert ((ConvertTo-RefreshUtcStamp '2026-11-10T17:07:31.787Z') -like '2026-11-10T17:07:31*Z') "A Z-suffixed time should keep its instant"
Assert ((ConvertTo-RefreshUtcStamp '2026-11-10T18:15:12.18') -like '2026-11-10T18:15:12*Z') "An unmarked time is UTC and must gain the designator"
$expectedLocal = ([datetime]::SpecifyKind([datetime]'2026-11-10T18:15:12.18', [System.DateTimeKind]::Utc)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
Assert ((Format-ValidationCompletedAt (ConvertTo-RefreshUtcStamp '2026-11-10T18:15:12.18')) -eq $expectedLocal) "An unmarked model time should render in local time"
Assert ((Format-ValidationCompletedAt $null) -eq '-') "A missing completion time renders as a dash"
Assert ((ConvertTo-DataflowOutcome "Failed") -eq "Failed" -and (ConvertTo-DataflowOutcome "Failure") -eq "Failed") "Both failure spellings count as a failure"
Assert ((ConvertTo-DataflowOutcome "Success") -eq "Succeeded" -and (ConvertTo-DataflowOutcome "InProgress") -eq "") "Success counts, a running transaction is not terminal"
Assert ($serverSource -notmatch 'graph\.microsoft\.com') "Graph must not be introduced into the Power BI token path"

# --- Refresh tab -> runner (convergence phase 5) ---------------------------------------
# The server starts runtime\Invoke-RefreshRun.ps1 instead of generating _worker.ps1 from
# the template with the token written into it.
foreach ($functionName in @("ConvertTo-RefreshProcessArgument", "New-RefreshRunnerStartInfo", "Test-RefreshWorkerAlive")) {
    $functionAst = $serverAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    Assert ($null -ne $functionAst) "Missing $functionName in server.ps1"
    Invoke-Expression $functionAst.Extent.Text
}
Assert ($serverSource -notmatch '\{\{Token\}\}') "The server must no longer write a token into a worker script"
Assert ($serverSource -notmatch '_refresh-worker-template\.ps1"\)\s*$' -and $serverSource -notmatch 'ReadAllText\(\$templatePath\)') "The server must no longer read the worker template"
Assert ($serverSource -match 'runtime\\Invoke-RefreshRun\.ps1') "The server must start the shared runner"

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("refresh tests " + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $sandbox | Out-Null
try {
    $fakeToken = "fake-token-" + [Guid]::NewGuid().ToString("N")
    $request = Get-RefreshRequest ([pscustomobject]@{
        WorkspaceId = $workspaceId
        DataflowIds = @($dataflowId)
        SemanticModels = @(
            [pscustomobject]@{ WorkspaceId = $workspaceId; DatasetId = $datasetId },
            [pscustomobject]@{ WorkspaceId = $secondWorkspaceId; DatasetId = $secondDatasetId })
        NotificationRecipients = @("first@example.com", "second@example.com")
        EmailDryRun = $true
    })
    $runnerPath = Join-Path $sandbox "runtime dir\Invoke-RefreshRun.ps1"
    $statusPath = Join-Path $sandbox "refresh status.json"
    $errorPath = Join-Path $sandbox "logs dir\refresh-worker-errors.log"
    $psi = New-RefreshRunnerStartInfo -RefreshRequest $request -RunnerPath $runnerPath -StatusFile $statusPath -ErrorLogPath $errorPath -Token $fakeToken -AuthMode "service-principal"
    Assert ($psi.FileName -eq "powershell.exe" -and -not $psi.UseShellExecute -and $psi.CreateNoWindow) "The runner starts hidden through powershell.exe"
    Assert ($psi.Arguments -notmatch [regex]::Escape($fakeToken)) "The token must never appear in the arguments"
    Assert ($psi.Arguments -notmatch '2>') "No shell redirection: the runner has a parameter block and would reject it"
    Assert ($psi.EnvironmentVariables["POWERBI_REFRESH_INITIAL_TOKEN"] -eq $fakeToken) "The token travels in the child's environment"
    Assert ($psi.EnvironmentVariables["POWERBI_REFRESH_INITIAL_TOKEN_MODE"] -eq "service-principal") "The sign-in mode travels with it"
    Assert ($psi.Arguments -match '-PreviewEmail') "An email dry run becomes -PreviewEmail"
    Assert ($psi.Arguments -match '-Recipients "first@example.com,second@example.com"') "Recipients travel as one comma-separated value"
    Assert ($psi.Arguments -match '-Confirmed') "The runner is confirmed"
    $noToken = New-RefreshRunnerStartInfo -RefreshRequest $legacy -RunnerPath $runnerPath -StatusFile $statusPath -ErrorLogPath $errorPath
    Assert ([string]::IsNullOrEmpty($noToken.EnvironmentVariables["POWERBI_REFRESH_INITIAL_TOKEN"])) "Without a token nothing is handed over"
    $liveEmail = Get-RefreshRequest ([pscustomobject]@{ WorkspaceId = $workspaceId; DataflowIds = @($dataflowId); DatasetId = $datasetId; NotificationRecipients = @("first@example.com") })
    Assert ((New-RefreshRunnerStartInfo -RefreshRequest $liveEmail -RunnerPath $runnerPath -StatusFile $statusPath -ErrorLogPath $errorPath).Arguments -notmatch '-PreviewEmail') "A live email is not a preview"
    $modelOnlyArgs = (New-RefreshRunnerStartInfo -RefreshRequest $modelOnly -RunnerPath $runnerPath -StatusFile $statusPath -ErrorLogPath $errorPath).Arguments
    $modelOnlyPlan = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([regex]::Match($modelOnlyArgs, '-PlanBase64 (\S+)')).Groups[1].Value)) | ConvertFrom-Json
    Assert (@($modelOnlyPlan.DataflowIds).Count -eq 0 -and @($modelOnlyPlan.SemanticModels).Count -eq 1) "A model-only plan sends no dataflows and the model"
    Assert ($null -eq $modelOnlyPlan.PSObject.Properties["Dataflows"]) "A plan in the original form carries no Dataflows list"
    $crossArgs = (New-RefreshRunnerStartInfo -RefreshRequest $crossWorkspace -RunnerPath $runnerPath -StatusFile $statusPath -ErrorLogPath $errorPath).Arguments
    $crossPlan = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([regex]::Match($crossArgs, '-PlanBase64 (\S+)')).Groups[1].Value)) | ConvertFrom-Json
    Assert (@($crossPlan.Dataflows).Count -eq 1 -and @($crossPlan.Dataflows)[0].WorkspaceId -eq $secondWorkspaceId -and @($crossPlan.DataflowIds)[0] -eq $dataflowId) "The plan carries each dataflow's own workspace next to the original form"

    # Start the exact settings against a stand-in with the runner's own parameter block,
    # so quoting, binding and the hand-over are proven without touching the service.
    $realRunner = Join-Path $PSScriptRoot "runtime\Invoke-RefreshRun.ps1"
    $runnerAst = [System.Management.Automation.Language.Parser]::ParseFile($realRunner, [ref]$null, [ref]$null)
    $paramText = $runnerAst.ParamBlock.Extent.Text
    New-Item -ItemType Directory -Path (Split-Path -Parent $runnerPath) | Out-Null
    $standIn = "[CmdletBinding()]`r`n$paramText`r`n" + @'
$bound = [ordered]@{}
foreach ($key in $PSBoundParameters.Keys) { $bound[$key] = [string]$PSBoundParameters[$key] }
$bound["tokenSeen"] = [string]$env:POWERBI_REFRESH_INITIAL_TOKEN
$bound["modeSeen"] = [string]$env:POWERBI_REFRESH_INITIAL_TOKEN_MODE
[System.IO.File]::WriteAllText($StatusFile, ($bound | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
'@
    [System.IO.File]::WriteAllText($runnerPath, $standIn, (New-Object System.Text.UTF8Encoding($false)))
    $child = [System.Diagnostics.Process]::Start($psi)
    Assert ($child.WaitForExit(60000)) "The stand-in runner should finish"
    Assert ($child.ExitCode -eq 0) "The arguments must bind to the runner's parameters (exit $($child.ExitCode))"
    $seen = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
    Assert ($seen.StatusFile -eq $statusPath -and $seen.ErrorLogPath -eq $errorPath) "Paths with spaces arrive intact"
    Assert ($seen.Recipients -eq "first@example.com,second@example.com") "Recipients arrive as one value"
    Assert ($seen.PreviewEmail -eq "True" -and $seen.Confirmed -eq "True") "Switches arrive"
    Assert ($seen.tokenSeen -eq $fakeToken -and $seen.modeSeen -eq "service-principal") "The child sees the handed-over token and mode"
    $plan = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($seen.PlanBase64)) | ConvertFrom-Json
    Assert ($plan.WorkspaceId -eq $workspaceId -and @($plan.DataflowIds)[0] -eq $dataflowId) "The plan keeps the dataflow workspace and IDs"
    Assert ((@($plan.SemanticModels | ForEach-Object { "$($_.WorkspaceId)|$($_.DatasetId)" }) -join ";") -eq "$workspaceId|$datasetId;$secondWorkspaceId|$secondDatasetId") "The plan keeps every semantic model"
    Assert ($null -eq $plan.PSObject.Properties["NotificationRecipients"]) "Recipients are not duplicated into the plan"

    # A dead worker must not keep the tab on "already running".
    $workerPath = Join-Path $sandbox "refresh-worker.json"
    Assert (Test-RefreshWorkerAlive $workerPath) "No worker record counts as alive (a run started before the record existed)"
    $self = Get-Process -Id $PID
    [ordered]@{ pid = $PID; startTime = $self.StartTime.ToString("o") } | ConvertTo-Json | Set-Content -LiteralPath $workerPath
    Assert (Test-RefreshWorkerAlive $workerPath) "A running worker is alive"
    [ordered]@{ pid = $child.Id; startTime = $child.StartTime.ToString("o") } | ConvertTo-Json | Set-Content -LiteralPath $workerPath
    Assert (-not (Test-RefreshWorkerAlive $workerPath)) "A worker that exited is dead"
    [ordered]@{ pid = $PID; startTime = "2000-01-01T00:00:00.0000000+00:00" } | ConvertTo-Json | Set-Content -LiteralPath $workerPath
    Assert (-not (Test-RefreshWorkerAlive $workerPath)) "A reused process ID with another start time is not the worker"
    Assert ($serverSource -match 'running -and \(Test-RefreshWorkerAlive \$workerFile\)') "The start endpoint refuses only while the worker lives"
    Assert ($serverSource -match 'running -and -not \(Test-RefreshWorkerAlive \$workerFile\)\) \{ \$s\.running = \$false \}') "The status endpoint reports a dead worker as not running"
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

# An unverified (Unknown) item is shown red, like a failure.
$html = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "index.html"))
Assert ($html -match "const fail = \[[^\]]*'Unknown'") "The status dots treat Unknown as a failure"
Assert ($html -match "detail\.status === 'Unknown'\) cls = 'failed'") "Semantic model rows treat Unknown as a failure"

# Model only: a per-run box that sends no dataflows, never saved with the profile,
# and a neutral "skipped" dataflow dot decided from the status itself.
Assert ($html -match 'id="modelOnly"') "The Refresh tab has a Model only box"
Assert ($html -match "DataflowIds: modelOnly \? \[\] : validDfs") "Model only sends no dataflows"
Assert ($html -match "const modelOnly = document\.getElementById\('modelOnly'\)\.checked \|\| enteredDfs\.length === 0;") "A profile without dataflows runs model only without the box"
Assert ($html -notmatch "modelOnly[^\n]*localStorage|ModelOnly:") "Model only is not saved with the profile"
Assert (([regex]::Matches($html, "getElementById\('modelOnly'\)\.checked = false")).Count -ge 2) "Model only is cleared when another profile is selected or the form is reset"
Assert ($html -match "\(state\.dataflowDetails \|\| \[\]\)\.length === 0 && \(state\.semanticModelDetails \|\| \[\]\)\.length > 0") "The dataflow dot is marked skipped from the status itself"

Write-Host "Refresh contract tests OK"
