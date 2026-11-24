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

# Notification flow sign-in (refresh-email.ps1). A trigger URL with a sig key ("Anyone")
# is sent as it is; a URL without one ("Any user in my tenant" / "Specific users") is sent
# with a Power Automate token; a keyed call the flow refuses with 401/403 is sent once
# more with a token and without the key. A token goes only to an HTTPS Power Automate
# host. Nothing here signs in or calls the service: Invoke-RestMethod and the MSAL calls
# are replaced.
. (Join-Path $PSScriptRoot "refresh-email.ps1")
if (-not ("RefreshEmailTests.HttpError" -as [type])) {
    Add-Type -TypeDefinition @"
namespace RefreshEmailTests {
    public class FakeResponse { public int StatusCode; public FakeResponse(int code) { StatusCode = code; } }
    public class HttpError : System.Exception {
        public FakeResponse Response;
        public HttpError(int code) : base("The remote server returned an error: (" + code + ").") { Response = new FakeResponse(code); }
    }
}
"@
}
# Fictional trigger URLs, assembled from parts so release-check.ps1's trigger-URL rule
# (which guards against real ones) does not flag them.
$flowPath = "/workflows/0/triggers/manual/paths/" + "invoke"
$keyedUrl = "https://prod-00.westeurope.logic.azure.com:443" + $flowPath + "?api-version=2016-06-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=TESTKEY"
$signedInUrl = "https://example.00.environment.api.powerplatform.com:443/powerautomate/automations/direct" + $flowPath + "?api-version=1"
Assert (Test-RefreshFlowUrlHasKey $keyedUrl) "A URL with sig is an Anyone trigger"
Assert (-not (Test-RefreshFlowUrlHasKey $signedInUrl)) "A URL without sig needs a signed-in caller"
foreach ($trusted in @($keyedUrl, $signedInUrl)) { Assert (Test-RefreshFlowTrustedHost $trusted) "Power Automate hosts may receive a token: $trusted" }
foreach ($untrusted in @("http://prod-00.westeurope.logic.azure.com/x", "https://example.invalid/hook", "https://logic.azure.com/x", "https://evillogic.azure.com/x", "https://prod-00.logic.azure.com.example.com/x", "not a url")) {
    Assert (-not (Test-RefreshFlowTrustedHost $untrusted)) "No token may go to $untrusted"
}
$unkeyed = Get-RefreshFlowUrlWithoutKey $keyedUrl
Assert ($unkeyed -eq ("https://prod-00.westeurope.logic.azure.com" + $flowPath + "?api-version=2016-06-01")) "A signed-in call drops sp, sv and sig and keeps the path and api-version: $unkeyed"
Assert ((Get-RefreshFlowUrlWithoutKey ($keyedUrl.Replace("sig=", "SIG="))) -notmatch "(?i)sig=") "Key parameters are dropped whatever their case"
Assert ((Get-RefreshFlowUrlWithoutKey $signedInUrl) -match "/powerautomate/automations/direct/workflows/0/triggers/manual/paths/invoke\?api-version=1$") "A URL without a key keeps its path and query"

$global:FlowCalls = New-Object System.Collections.Generic.List[object]
$global:FlowAnswers = New-Object System.Collections.Generic.Queue[int]
$global:TokenRequests = 0
function Invoke-RestMethod {
    param([string]$Method, [string]$Uri, [hashtable]$Headers, [string]$ContentType, [byte[]]$Body, [int]$TimeoutSec, $ErrorAction)
    $global:FlowCalls.Add([pscustomobject]@{ Uri = $Uri; Authorization = [string]$Headers["Authorization"]; Body = [System.Text.Encoding]::UTF8.GetString($Body) })
    $answer = if ($global:FlowAnswers.Count) { $global:FlowAnswers.Dequeue() } else { 200 }
    if ($answer -ne 200) { throw (New-Object RefreshEmailTests.HttpError $answer) }
}
$tokenSource = { $global:TokenRequests++; "TEST-FLOW-TOKEN" }
function Reset-Flow([int[]]$Answers = @()) {
    $global:FlowCalls.Clear(); $global:FlowAnswers.Clear(); $global:TokenRequests = 0
    foreach ($a in $Answers) { $global:FlowAnswers.Enqueue($a) }
}
function Send-TestEmail([string]$Url, [scriptblock]$Source) {
    return Send-RefreshEmail -WebhookUrl $Url -Recipients @("a@example.com", "b@example.com") -Subject "S" -HtmlBody "<p>B</p>" -GetAccessToken $Source
}

Reset-Flow
$sent = Send-TestEmail $keyedUrl $tokenSource
Assert ($global:FlowCalls.Count -eq 1 -and $global:FlowCalls[0].Authorization -eq "" -and $global:TokenRequests -eq 0 -and -not $sent.SignedIn) "An Anyone flow gets one call without a token, and no token is requested"
$payload = $global:FlowCalls[0].Body | ConvertFrom-Json
Assert ((@($payload.PSObject.Properties.Name) -join ",") -eq "recipients,subject,htmlBody" -and @($payload.recipients).Count -eq 2) "The request body keeps exactly recipients, subject and htmlBody"

Reset-Flow
$sent = Send-TestEmail $signedInUrl $tokenSource
Assert ($global:FlowCalls.Count -eq 1 -and $global:FlowCalls[0].Authorization -eq "Bearer TEST-FLOW-TOKEN" -and $global:TokenRequests -eq 1 -and $sent.SignedIn) "A flow without a URL key gets one call with a Power Automate token"

Reset-Flow @(401)
$sent = Send-TestEmail $keyedUrl $tokenSource
Assert ($global:FlowCalls.Count -eq 2 -and $global:FlowCalls[0].Authorization -eq "" -and $global:FlowCalls[1].Authorization -eq "Bearer TEST-FLOW-TOKEN" -and $sent.SignedIn) "A keyed call refused with 401 is sent once more with a token"
Assert ($global:FlowCalls[0].Uri -eq $keyedUrl -and $global:FlowCalls[1].Uri -eq $unkeyed) "The retry carries the token instead of the URL key, never both"

Reset-Flow @(403)
$failure = ""; try { Send-TestEmail $keyedUrl $null | Out-Null } catch { $failure = $_.Exception.Message }
Assert ($global:FlowCalls.Count -eq 1 -and $failure -match "\(403\)") "Without a token source a refused keyed call fails as it is"

Reset-Flow @(500)
$failure = ""; try { Send-TestEmail $keyedUrl $tokenSource | Out-Null } catch { $failure = $_.Exception.Message }
Assert ($global:FlowCalls.Count -eq 1 -and $global:TokenRequests -eq 0 -and $failure -match "\(500\)") "Other failures are not retried and request no token"

Reset-Flow
$failure = ""; try { Send-TestEmail "https://example.invalid/hook" $tokenSource | Out-Null } catch { $failure = $_.Exception.Message }
Assert ($global:FlowCalls.Count -eq 0 -and $global:TokenRequests -eq 0 -and $failure -match "not an HTTPS Power Automate address") "No token is requested or sent for a URL off the Power Automate hosts"

Reset-Flow @(403)
$failure = ""; try { Send-TestEmail $signedInUrl $tokenSource | Out-Null } catch { $failure = $_.Exception.Message }
Assert ($global:FlowCalls.Count -eq 1 -and $failure -match "refused the signed-in call \(HTTP 403\)" -and $failure -notmatch "TEST-FLOW-TOKEN") "A refused signed-in call names the trigger setting and never the token"

Reset-Flow
$failure = ""; try { Send-TestEmail $signedInUrl $null | Out-Null } catch { $failure = $_.Exception.Message }
Assert ($global:FlowCalls.Count -eq 0 -and $failure -match "no Power Automate sign-in is available") "A flow without a URL key and no sign-in fails before calling"

# The flow token comes from the refresh's own sign-in, for the flow service audience.
$global:MsalCalls = New-Object System.Collections.Generic.List[object]
function Get-MsalToken {
    param($PublicClientApplication, $ConfidentialClientApplication, [string[]]$Scopes, [switch]$Silent, [switch]$ForceRefresh, $ErrorAction)
    $global:MsalCalls.Add([pscustomobject]@{ Scopes = $Scopes; Silent = [bool]$Silent; Confidential = $null -ne $ConfidentialClientApplication })
    if ($global:MsalFails) { throw "AADSTS65001: consent required. access_token=SECRETVALUE" }
    return [pscustomobject]@{ AccessToken = "FLOW-TOKEN" }
}
function New-PowerBiClientAssertion { param($Certificate, $ClientId, $Audience) return "ASSERTION" }
function New-MsalClientApplication { param($ClientId, $TenantId, $ClientAssertion, $ErrorAction) return [pscustomobject]@{ Kind = "confidential" } }
$global:MsalFails = $false
$delegated = [pscustomobject]@{ Mode = "delegated"; Client = [pscustomobject]@{ Kind = "public" } }
Assert ((Get-RefreshFlowAccessToken -Context $delegated) -eq "FLOW-TOKEN") "Device-code sign-in yields a flow token"
Assert ($global:MsalCalls[0].Silent -and -not $global:MsalCalls[0].Confidential -and (@($global:MsalCalls[0].Scopes) -join "") -eq "https://service.flow.microsoft.com//.default") "Device-code sign-in asks silently for the flow service audience"
$certificate = [pscustomobject]@{ Mode = "service-principal"; Certificate = $null; ClientId = "c"; TenantId = "t"; TokenEndpoint = "e" }
Assert ((Get-RefreshFlowAccessToken -Context $certificate) -eq "FLOW-TOKEN") "The certificate app yields a flow token"
Assert ($global:MsalCalls[1].Confidential -and (@($global:MsalCalls[1].Scopes) -join "") -eq "https://service.flow.microsoft.com//.default") "The certificate app asks for the flow service audience"
$global:MsalFails = $true
$failure = ""; try { Get-RefreshFlowAccessToken -Context $delegated | Out-Null } catch { $failure = $_.Exception.Message }
Assert ($failure -match "Power Automate token could not be obtained \(delegated sign-in\)" -and $failure -match "AADSTS65001" -and $failure -notmatch "SECRETVALUE") "A failed flow sign-in explains itself and hides token-shaped text"
Remove-Item Function:\Invoke-RestMethod, Function:\Get-MsalToken, Function:\New-PowerBiClientAssertion, Function:\New-MsalClientApplication

Write-Host "Refresh contract tests OK"
