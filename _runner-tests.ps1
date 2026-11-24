# Offline tests for the refresh runner (runtime\refresh-engine.ps1). The Power BI
# service is replaced by an in-memory fake: nothing signs in, nothing is refreshed,
# and no email is sent. Output files go to a temporary folder that is removed.

$ErrorActionPreference = "Stop"

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

. (Join-Path $PSScriptRoot "_refresh-contract.ps1")
. (Join-Path $PSScriptRoot "runtime\refresh-engine.ps1")
$script:RefreshQuiet = $true
$script:RefreshUnreadableLimit = 3
# 36 seconds instead of 11 hours: a run that never sees its own result times out
# here instead of hanging the tests.
$script:RefreshBudgetHours = 0.01

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("runner-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $sandbox | Out-Null

# The real email builder, with the send captured instead of posted.
$global:RunnerTestSent = New-Object System.Collections.Generic.List[object]
$fakeEmailModule = Join-Path $sandbox "fake-email.ps1"
$realEmailModule = Join-Path $PSScriptRoot "refresh-email.ps1"
[System.IO.File]::WriteAllText($fakeEmailModule, @"
. '$realEmailModule'
function Send-RefreshEmail {
    param([string]`$WebhookUrl, [string[]]`$Recipients, [string]`$Subject, [string]`$HtmlBody, [scriptblock]`$GetAccessToken)
    `$global:RunnerTestSent.Add([pscustomobject]@{ Recipients = `$Recipients; Subject = `$Subject; HtmlBody = `$HtmlBody; HasTokenSource = (`$null -ne `$GetAccessToken) })
    return [pscustomobject]@{ SignedIn = `$false }
}
"@)

# --- fake service ---------------------------------------------------------------------------
$script:Ids = @{}
foreach ($key in @("ws", "ws2", "dfws", "report", "model", "model2", "df1", "df2", "df3")) { $script:Ids[$key] = [Guid]::NewGuid().ToString() }

function Reset-FakeService {
    param(
        [hashtable]$DataflowScripts = @{},
        [string[]]$ModelScript = @("Unknown", "Completed"),
        [bool]$ModelLocation = $true,
        [bool]$ModelBusy = $false,
        # Busy answers of the model history, one per read, before falling back to
        # ModelBusy: the run-start check reads the first one.
        [bool[]]$BusySteps = @(),
        # Model refresh POSTs refused with a 400 before one is accepted.
        [int]$RefusePosts = 0,
        # The refusal is not caused by another refresh (no other refresh ends then).
        [bool]$RefuseWithoutOther = $false,
        [string]$Webhook = "https://example.invalid/hook"
    )
    $script:Fake = @{
        Calls = New-Object System.Collections.Generic.List[string]
        DataflowScripts = $DataflowScripts
        DataflowPolls = @{}
        DataflowTriggers = @{}
        ModelScript = $ModelScript
        ModelPolls = @{}
        ModelTriggers = @{}
        ModelLocation = $ModelLocation
        ModelBusy = $ModelBusy
        BusySteps = New-Object System.Collections.Generic.Queue[bool] (, [bool[]]$BusySteps)
        RefusePosts = $RefusePosts
        RefuseWithoutOther = $RefuseWithoutOther
        LastOtherEnd = $null
        Webhook = $Webhook
    }
    $global:RunnerTestSent.Clear()
    # The validation queries: row counts per table, "before" until the model refresh is
    # triggered and "after" from then on. Fail makes every query throw.
    $script:FakeValidation = @{ Phase = "before"; Fail = $false; Queries = New-Object System.Collections.Generic.List[string]
        Before = @{ "Sales" = 100; "Dim" = 10; "Gone" = 5 }; After = @{ "Sales" = 104; "Dim" = 10; "New" = 3 } }
}

function Get-FakeStep {
    param([string[]]$Script, [int]$Poll)
    if ($Script.Count -eq 0) { return "Success" }
    return $Script[[math]::Min($Poll, $Script.Count - 1)]
}

function Invoke-PowerBiRequest {
    param([string]$Method, [string]$Uri, [string]$Body)

    $script:Fake.Calls.Add("$Method $Uri")
    $path = $Uri.Substring("https://api.powerbi.com/v1.0/myorg".Length)
    $ids = $script:Ids
    $yesterday = (Get-Date).ToUniversalTime().AddDays(-1)
    $names = @{ $ids.df1 = "DF One"; $ids.df2 = "DF Two"; $ids.df3 = "DF, Three" }

    if ($Method -eq "GET" -and $path -eq "/groups") {
        return [pscustomobject]@{ value = @(
            [pscustomobject]@{ id = $ids.ws; name = "Sales TEST" },
            [pscustomobject]@{ id = $ids.ws2; name = "Other" },
            [pscustomobject]@{ id = $ids.dfws; name = "Dataflows" }) }
    }
    if ($Method -eq "GET" -and $path -eq "/groups/$($ids.ws)/reports") {
        return [pscustomobject]@{ value = @([pscustomobject]@{ id = $ids.report; name = "Sales Report"; datasetId = $ids.model }) }
    }
    if ($Method -eq "GET" -and $path -match '^/groups/([^/]+)/datasets/upstreamDataflows$') {
        return [pscustomobject]@{ value = @(
            foreach ($df in @($ids.df1, $ids.df2, $ids.df3)) {
                [pscustomobject]@{ datasetObjectId = $ids.model; workspaceObjectId = $ids.dfws; dataflowObjectId = $df }
            }) }
    }
    if ($Method -eq "GET" -and $path -match '^/groups/([^/]+)$') {
        $map = @{ $ids.ws = "Sales TEST"; $ids.ws2 = "Other"; $ids.dfws = "Dataflows" }
        return [pscustomobject]@{ name = $map[$Matches[1]] }
    }
    if ($Method -eq "GET" -and $path -match '^/groups/([^/]+)/datasets/([^/?]+)$') {
        $ws = $Matches[1]; $ds = $Matches[2]
        if ($ds -eq $ids.model -and $ws -eq $ids.ws) { return [pscustomobject]@{ id = $ds; name = "Sales Model"; isRefreshable = $true } }
        if ($ds -eq $ids.model2 -and $ws -eq $ids.ws2) { return [pscustomobject]@{ id = $ds; name = "Second Model"; isRefreshable = $true } }
        throw "Response status code does not indicate success: 404 (Not Found)."
    }
    if ($Method -eq "GET" -and $path -match '^/groups/([^/]+)/dataflows/([^/]+)$') {
        return [pscustomobject]@{ name = $names[$Matches[2]] }
    }
    if ($Method -eq "POST" -and $path -match '^/groups/([^/]+)/dataflows/([^/]+)/refreshes$') {
        $script:Fake.DataflowTriggers[$Matches[2]] = (Get-Date).ToUniversalTime().AddSeconds(1).ToString("o")
        $script:Fake.DataflowPolls[$Matches[2]] = 0
        return $null
    }
    if ($Method -eq "GET" -and $path -match '^/groups/([^/]+)/dataflows/([^/]+)/transactions$') {
        $id = $Matches[2]
        $poll = [int]$script:Fake.DataflowPolls[$id]
        $script:Fake.DataflowPolls[$id] = $poll + 1
        $steps = if ($script:Fake.DataflowScripts.ContainsKey($id)) { $script:Fake.DataflowScripts[$id] } else { @("Success") }
        $step = Get-FakeStep $steps $poll
        if ($step -eq "error") { throw "Response status code does not indicate success: 500 (Internal Server Error)." }
        if ($step -eq "notfound") { throw "Response status code does not indicate success: 404 (Not Found)." }
        $old = [pscustomobject]@{ startTime = $yesterday.ToString("o"); endTime = $yesterday.AddMinutes(5).ToString("o"); status = "Success" }
        if ($step -eq "none") { return [pscustomobject]@{ value = @($old) } }
        $status = if ($step -eq "running") { "InProgress" } else { $step }
        $end = if ($step -eq "running") { $null } else { (Get-Date).ToUniversalTime().ToString("o") }
        $current = [pscustomobject]@{ startTime = $script:Fake.DataflowTriggers[$id]; endTime = $end; status = $status; error = if ($step -eq "Failed") { "Mashup error in query X" } else { $null } }
        return [pscustomobject]@{ value = @($old, $current) }
    }
    if ($Method -eq "GET" -and $path -match '^/groups/([^/]+)/datasets/([^/]+)/refreshes\?\$top=1$') {
        $busy = if ($script:Fake.BusySteps.Count -gt 0) { $script:Fake.BusySteps.Dequeue() } else { $script:Fake.ModelBusy }
        # Another refresh: running, or just finished (when a POST was refused moments ago).
        if ($busy) { return [pscustomobject]@{ value = @([pscustomobject]@{ startTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.ff"); endTime = $null; status = "Unknown" }) } }
        $end = if ($null -ne $script:Fake.LastOtherEnd) { $script:Fake.LastOtherEnd } else { $yesterday.ToString("yyyy-MM-ddTHH:mm:ss.ff") }
        return [pscustomobject]@{ value = @([pscustomobject]@{ startTime = $yesterday.ToString("yyyy-MM-ddTHH:mm:ss.ff"); endTime = $end; status = "Completed" }) }
    }
    if ($Method -eq "GET" -and $path -match '^/groups/([^/]+)/datasets/([^/]+)/refreshes(\?\$top=10|/req-.+)$') {
        $id = $Matches[2]
        $poll = [int]$script:Fake.ModelPolls[$id]
        $script:Fake.ModelPolls[$id] = $poll + 1
        $step = Get-FakeStep $script:Fake.ModelScript $poll
        if ($step -eq "error") { throw "Response status code does not indicate success: 500 (Internal Server Error)." }
        # Refresh history carries UTC times without a zone designator.
        $start = ([datetime]$script:Fake.ModelTriggers[$id]).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.ff")
        $end = if ($step -eq "Unknown") { $null } else { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.ff") }
        $row = [pscustomobject]@{ startTime = $start; endTime = $end; status = $step; serviceExceptionJson = if ($step -eq "Failed") { '{"errorCode":"ModelRefreshFailed"}' } else { $null } }
        if ($Uri -like '*$top=10') {
            $old = [pscustomobject]@{ startTime = $yesterday.ToString("yyyy-MM-ddTHH:mm:ss.ff"); endTime = $yesterday.ToString("yyyy-MM-ddTHH:mm:ss.ff"); status = "Completed" }
            return [pscustomobject]@{ value = @($row, $old) }
        }
        return $row
    }
    throw "Fake service: unexpected call $Method $path"
}

function Invoke-PowerBiWebRequest {
    param([string]$Method, [string]$Uri, [string]$Body)

    $script:Fake.Calls.Add("$Method $Uri")
    if ($Method -eq "POST" -and $Uri -match '/groups/([^/]+)/datasets/([^/]+)/refreshes$') {
        if ($script:Fake.RefusePosts -gt 0) {
            # Refused like the service refuses it: the status line in the exception,
            # the reason in the body (ErrorDetails), and the other refresh ending now.
            $script:Fake.RefusePosts--
            if (-not $script:Fake.RefuseWithoutOther) { $script:Fake.LastOtherEnd = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.ff") }
            $record = New-Object System.Management.Automation.ErrorRecord((New-Object System.Exception "The remote server returned an error: (400) Bad Request."), "FakeRefused", "InvalidOperation", $null)
            $record.ErrorDetails = New-Object System.Management.Automation.ErrorDetails '{"error":{"code":"InvalidRequest","message":"Another refresh request is already executing"}}'
            throw $record
        }
        $script:Fake.ModelTriggers[$Matches[2]] = (Get-Date).ToUniversalTime().AddSeconds(1).ToString("o")
        $script:Fake.ModelPolls[$Matches[2]] = 0
        $script:FakeValidation.Phase = "after"
        $headers = @{}
        if ($script:Fake.ModelLocation) { $headers["Location"] = "$Uri/req-$([Guid]::NewGuid().ToString('N'))" }
        return [pscustomobject]@{ Headers = $headers }
    }
    throw "Fake service: unexpected web call $Method $Uri"
}

function Initialize-RefreshAuthorization {
    param([string]$InitialToken, [string]$InitialMode)
    $script:RefreshAuthMode = if ($InitialToken) { "$InitialMode (Control Panel sign-in)" } else { "test" }
}
function Wait-RefreshPollInterval { }
function Get-RefreshWebhookUrl { return $script:Fake.Webhook }
# Validation runs offline too: no sign-in, and the DAX queries answered from the fake.
function Confirm-RefreshAuthorization { }
$script:RefreshHeaders = @{ Authorization = "Bearer fake-token-for-tests" }

function Invoke-ValidationQuery {
    param([string]$WorkspaceId, [string]$DatasetId, [hashtable]$Headers, [string]$Query)

    $script:FakeValidation.Queries.Add($Query)
    if ($script:FakeValidation.Fail) { throw "Validation query failed with HTTP 400: fake failure" }
    $counts = if ($script:FakeValidation.Phase -eq "after") { $script:FakeValidation.After } else { $script:FakeValidation.Before }
    if ($Query -like '*INFO.VIEW.TABLES()*"IsPrivate"*') {
        # Every table, plus the ones the universal check must skip: an automatic date
        # table, a calculation group and a measures-only table without columns.
        $tables = @($counts.Keys) + @("LocalDateTable_x", "Calc group", "Measures")
        return @(foreach ($name in $tables) {
            [pscustomobject]@{ "[Name]" = $name; "[IsPrivate]" = $false; "[StorageMode]" = "Import"; "[CalculationGroupPrecedence]" = $(if ($name -eq "Calc group") { 1 } else { $null }) }
        })
    }
    if ($Query -like '*INFO.VIEW.COLUMNS()*"Table", `[Table`]*') {
        return @(foreach ($name in @($counts.Keys) + @("LocalDateTable_x", "Calc group")) { [pscustomobject]@{ "[Table]" = $name } })
    }
    if ($Query -like 'EVALUATE UNION(*' -or $Query -like 'EVALUATE ROW("Table"*') {
        if ($Query -match "Measures'|LocalDateTable|Calc group") { throw "Validation query failed with HTTP 400: a skipped table was counted" }
        return @(foreach ($name in @($counts.Keys)) { if ($Query -like "*'$name'*") { [pscustomobject]@{ "[Table]" = $name; "[Rows]" = $counts[$name] } } })
    }
    if ($Query -like '*INFO.VIEW.*') { return @([pscustomobject]@{ "[Key]" = "Sales" }) }
    if ($Query -like '*SalesValue*') { return @([pscustomobject]@{ "[Value]" = $(if ($script:FakeValidation.Phase -eq "after") { 1100 } else { 1000 }) }) }
    throw "Fake validation: unexpected query $Query"
}

function Invoke-Scenario {
    param([hashtable]$Arguments)

    $name = [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $runsRoot = Join-Path $sandbox "$name\PowerBIChainedRefresh\runs"
    $statusFile = Join-Path $sandbox "$name-status.json"
    $outcome = [pscustomobject]@{ Result = $null; Error = ""; Status = $null; RunsRoot = $runsRoot; StatusFile = $statusFile; Log = "" }
    try {
        $outcome.Result = Invoke-RefreshRun @Arguments -RunsRoot $runsRoot -StatusFile $statusFile -EmailModulePath $fakeEmailModule
    } catch {
        $outcome.Error = $_.Exception.Message
    }
    if (Test-Path -LiteralPath $statusFile) { $outcome.Status = [System.IO.File]::ReadAllText($statusFile) | ConvertFrom-Json }
    if ($null -ne $outcome.Result -and $outcome.Result.RunFolder) {
        $outcome.Log = [System.IO.File]::ReadAllText((Join-Path $outcome.Result.RunFolder "refresh-log.txt"))
    }
    return $outcome
}

function Get-PostCount {
    param([string]$Fragment)
    return @($script:Fake.Calls | Where-Object { $_ -like "POST *$Fragment*" }).Count
}

function Assert-LocksReleased {
    param([object]$Outcome)
    $locks = Join-Path (Split-Path -Parent $Outcome.RunsRoot) "locks"
    Assert (@(Get-ChildItem -LiteralPath $locks -ErrorAction SilentlyContinue).Count -eq 0) "Every run lock must be released"
}

$byName = @{ WorkspaceName = "Sales TEST"; ReportName = "Sales Report"; Recipients = @("ops@example.com"); Confirmed = $true }
$checks = 0

try {
    # 1. Report by name, one dataflow excluded, a previous run's transaction ignored.
    Reset-FakeService -DataflowScripts @{ $script:Ids.df1 = @("none", "running", "Success"); $script:Ids.df3 = @("running", "Success") }
    $run = Invoke-Scenario ($byName + @{ ExcludeDataflow = @("DF Two") })
    Assert ($run.Error -eq "") "A successful run must not throw: $($run.Error)"
    $summary = Get-Content -LiteralPath (Join-Path $run.Result.RunFolder "summary.json") -Raw | ConvertFrom-Json
    Assert ($summary.Result -eq "Succeeded") "The run should succeed: $($run.Log)"
    $summaryFields = @($summary.PSObject.Properties.Name)
    Assert ((@($summaryFields | Where-Object { $RefreshSummaryFields -notcontains $_ }).Count + @($RefreshSummaryFields | Where-Object { $summaryFields -notcontains $_ }).Count) -eq 0) "summary.json must carry exactly the contract fields"
    foreach ($item in @($summary.Dataflows) + @($summary.SemanticModels)) {
        Assert ((@($item.PSObject.Properties.Name) -join ",") -eq ($RefreshSummaryItemFields -join ",")) "Summary items must carry the contract fields"
    }
    Assert ((@($summary.ExcludedDataflows) -join "|") -eq "DF Two") "The excluded dataflow is recorded"
    Assert ((Get-PostCount $script:Ids.df2) -eq 0) "An excluded dataflow must never be refreshed"
    Assert ((@($summary.Dataflows | ForEach-Object { $_.name }) -join "|") -eq "DF One|DF, Three") "A dataflow name with a comma survives"
    $dfOne = @($summary.Dataflows | Where-Object { $_.name -eq "DF One" })[0]
    Assert ((ConvertTo-RefreshUtcDate $dfOne.completedAt) -gt (Get-Date).ToUniversalTime().AddHours(-1)) "The previous run's transaction must not be reported as this run's"
    Assert ($run.Log -match ("\| " + [regex]::Escape(($RefreshLogFirstLinePattern -f "Sales Report", "Sales TEST")))) "The first log line follows the contract"
    Assert (@($summary.SemanticModels)[0].completedAt -like "*Z") "Model completion times are explicit UTC"
    $statusFields = @($run.Status.PSObject.Properties.Name)
    Assert ((@($statusFields | Where-Object { $RefreshStatusFields -notcontains $_ }).Count + @($RefreshStatusFields | Where-Object { $statusFields -notcontains $_ }).Count) -eq 0) "The status file must carry exactly the contract fields"
    Assert (-not $run.Status.running -and $run.Status.result -eq "Succeeded") "The status file ends Succeeded"
    Assert ($run.Status.dataflowStatus -eq "Success" -and $run.Status.datasetStatus -eq "Completed") "The status file uses the UI's success words"
    foreach ($detail in @($run.Status.semanticModelDetails)) {
        foreach ($field in $RefreshModelDetailUiFields) { Assert ($detail.PSObject.Properties.Name -contains $field) "Model details must carry '$field'" }
    }
    $logEntry = @($run.Status.logs)[0]
    Assert ((@($logEntry.PSObject.Properties.Name) -join ",") -eq ($RefreshLogEntryFields -join ",")) "Log entries carry time and text"
    Assert ($run.Status.emailStatus -eq "Sent" -and $global:RunnerTestSent.Count -eq 1) "One email is sent"
    Assert $global:RunnerTestSent[0].HasTokenSource "The runner offers a Power Automate sign-in for flows that require one"
    Assert ($global:RunnerTestSent[0].Subject -match "Sales Report: refresh OK, \d+/\d+ checks passed") "The validated email names the report and the checks: $($global:RunnerTestSent[0].Subject)"
    # Universal validation: no report config matches "Sales TEST", so rows per table and
    # the model structure are compared before and after.
    Assert ($summary.Validation.Models.Count -eq 1 -and $summary.Validation.Models[0].checks -eq "universal") "The model is validated with the universal checks"
    Assert ($summary.Validation.Overall -eq "WARN") "A table that is no longer counted warns (got $($summary.Validation.Overall))"
    Assert (Test-Path -LiteralPath (Join-Path $run.Result.RunFolder "email.html")) "The email is kept in the run folder"
    foreach ($phase in @("before", "after", "compare")) {
        Assert (Test-Path -LiteralPath (Join-Path $run.Result.RunFolder "validation-1-$phase.json")) "The $phase snapshot is kept"
    }
    $compare = [System.IO.File]::ReadAllText((Join-Path $run.Result.RunFolder "validation-1-compare.json")) | ConvertFrom-Json
    $rowsCheck = @($compare.checks | Where-Object { $_.id -eq "rows_per_table" })[0]
    Assert ((@($rowsCheck.months | ForEach-Object { $_.key }) -join "|") -eq "Dim|Gone|New|Sales") "Measures-only, auto-date and calculation-group tables are not counted (got $(@($rowsCheck.months | ForEach-Object { $_.key }) -join '|'))"
    $body = $global:RunnerTestSent[0].HtmlBody
    Assert ($body -match "Rows per table" -and $body -match "universal checks") "The email shows the universal checks"
    Assert ($run.Log -match "Validation of semantic model 'Sales Model': WARN") "The verdict is logged"
    Assert-LocksReleased $run
    $checks++

    # 2. A failed dataflow skips the model, still emails, and fails the run.
    Reset-FakeService -DataflowScripts @{ $script:Ids.df2 = @("running", "Failed") }
    $run = Invoke-Scenario $byName
    Assert ($run.Result.Failed -and $run.Result.Summary.Result -eq "Failed") "A failed dataflow fails the run"
    $failedDf = @($run.Result.Summary.Dataflows | Where-Object { $_.name -eq "DF Two" })[0]
    Assert ($failedDf.status -eq "Failed" -and $failedDf.error -eq "Mashup error in query X") "The service error is kept"
    Assert (@($run.Result.Summary.SemanticModels)[0].status -eq "Skipped") "The model is skipped"
    Assert ((Get-PostCount "/datasets/") -eq 0) "The model refresh is never started"
    Assert ($run.Status.dataflowStatus -eq "Failed" -and $run.Status.datasetStatus -eq "Skipped" -and $run.Status.result -eq "Failed") "The status file shows the failure"
    Assert ($global:RunnerTestSent.Count -eq 1 -and $global:RunnerTestSent[0].Subject -match "refresh failed") "The failure is emailed"
    Assert-LocksReleased $run
    $checks++

    # 3. A status that stays unreadable ends Unknown, never Failed, and skips the model.
    Reset-FakeService -DataflowScripts @{ $script:Ids.df1 = @("error") }
    $run = Invoke-Scenario $byName
    $unknown = @($run.Result.Summary.Dataflows | Where-Object { $_.name -eq "DF One" })[0]
    Assert ($unknown.status -eq "Unknown") "An unreadable status ends Unknown"
    Assert ($unknown.error -like "Status unreadable after 3 consecutive attempts*") "The reason says it was unreadable"
    $skipped = @($run.Result.Summary.SemanticModels)[0]
    Assert ($skipped.status -eq "Skipped" -and $skipped.error -like "*could not be verified*") "The model skip does not claim a failure"
    Assert ($run.Result.Failed) "An unverified chain is not a success"
    Assert ((Get-PostCount $script:Ids.df1) -eq 1) "No second refresh is started"
    $checks++

    # 4. A brief unreadable spell is ridden out.
    Reset-FakeService -DataflowScripts @{ $script:Ids.df1 = @("error", "error", "Success") }
    $run = Invoke-Scenario $byName
    Assert (-not $run.Result.Failed) "Two unreadable polls under the limit do not fail the run"
    Assert ($run.Log -match "status readable again after 2 failed attempt") "Recovery is logged"
    $checks++

    # 5. A 404 on the transactions never starts a second refresh (the old worker did,
    #    and then marked the dataflow Succeeded without seeing a result).
    Reset-FakeService -DataflowScripts @{ $script:Ids.df1 = @("notfound", "notfound", "Success") }
    $run = Invoke-Scenario $byName
    Assert ((Get-PostCount $script:Ids.df1) -eq 1) "A 404 must not trigger another refresh"
    Assert (-not $run.Result.Failed) "The dataflow succeeds once its status is readable"
    $checks++

    # 6. A model refresh accepted without a Location header is followed in the history,
    #    whose times carry no zone designator.
    Reset-FakeService -ModelLocation $false -ModelScript @("Unknown", "Unknown", "Completed")
    $run = Invoke-Scenario $byName
    Assert (-not $run.Result.Failed) "The history fallback finds this run's refresh"
    Assert ($run.Log -match "accepted without a status location") "The fallback is logged"
    $checks++

    # 7. A Control Panel profile: IDs, two models in two workspaces, email preview.
    Reset-FakeService
    $plan = [pscustomobject]@{
        WorkspaceId = $script:Ids.dfws
        DataflowIds = @($script:Ids.df1)
        SemanticModels = @(
            [pscustomobject]@{ WorkspaceId = $script:Ids.ws; DatasetId = $script:Ids.model },
            [pscustomobject]@{ WorkspaceId = $script:Ids.ws2; DatasetId = $script:Ids.model2 })
    }
    $run = Invoke-Scenario @{ Plan = $plan; Recipients = @("ops@example.com"); PreviewEmail = $true; Confirmed = $true; InitialToken = "token-from-the-control-panel"; InitialMode = "service-principal" }
    Assert (-not $run.Result.Failed) "A profile run succeeds: $($run.Error)"
    Assert ($run.Result.Summary.Report -eq "" -and $run.Result.Summary.Workspace -eq "Dataflows") "A profile run has no report and names the dataflow workspace"
    Assert ((@($run.Status.semanticModelDetails | ForEach-Object { $_.name }) -join "|") -eq "Sales Model|Second Model") "Both models are refreshed and named"
    Assert ($run.Result.Summary.EmailStatus -eq "Preview" -and $global:RunnerTestSent.Count -eq 0) "A preview sends nothing"
    Assert ($run.Result.Summary.Authentication -eq "service-principal (Control Panel sign-in)") "The handed-over sign-in and its mode are recorded"
    Assert ($run.Log -match "Starting refresh plan in workspace 'Dataflows'") "A profile run has its own first line"
    Assert (@($run.Status.dataflowDetails)[0].id -eq $script:Ids.df1) "Status details keep the IDs the UI falls back to"
    $checks++

    # 8. A model already refreshing in the service: refused before anything starts.
    Reset-FakeService -ModelBusy $true
    $run = Invoke-Scenario $byName
    Assert ($run.Error -like "*already refreshing in the Power BI service*") "A busy model is refused"
    Assert (@($script:Fake.Calls | Where-Object { $_ -like "POST *" }).Count -eq 0) "Nothing is triggered"
    Assert (-not $run.Status.running -and $run.Status.result -eq "Failed" -and $run.Status.error -like "*already refreshing*") "The status file explains the refusal"
    Assert-LocksReleased $run
    $checks++

    # 9. A second run for the same model while the first is alive: refused.
    Reset-FakeService
    $lockedRoot = Join-Path $sandbox "locked\PowerBIChainedRefresh\runs"
    $lockPath = Get-RefreshLockPath -RunsRoot $lockedRoot -WorkspaceId $script:Ids.ws -DatasetId $script:Ids.model
    Enter-RefreshRunLock -Path $lockPath -RunFolder "first run"
    $refusedError = ""
    try { Invoke-RefreshRun @byName -RunsRoot $lockedRoot -EmailModulePath $fakeEmailModule | Out-Null } catch { $refusedError = $_.Exception.Message }
    Assert ($refusedError -like "*already active*") "A held lock refuses the run"
    Assert (@($script:Fake.Calls | Where-Object { $_ -like "POST *" }).Count -eq 0) "Nothing is triggered while locked"
    Assert (Test-Path -LiteralPath $lockPath) "The other run's lock is left alone"
    Exit-RefreshRunLock -Path $lockPath
    $checks++

    # 10. Without -Confirmed only the plan is shown.
    Reset-FakeService
    $run = Invoke-Scenario @{ WorkspaceName = "Sales TEST"; ReportName = "Sales Report" }
    Assert ($null -eq $run.Result -and $run.Error -eq "") "A plan-only call returns nothing"
    Assert (@($script:Fake.Calls | Where-Object { $_ -like "POST *" }).Count -eq 0) "A plan-only call triggers nothing"
    Assert (-not (Test-Path -LiteralPath $run.RunsRoot)) "A plan-only call creates no run folder"
    Assert ($null -eq $run.Status) "A plan-only call writes no status file"
    # The report plan keeps the skill's fields and shows the model by name.
    $view = Write-RefreshPlan -Plan (Resolve-RefreshPlanByName -WorkspaceName "Sales TEST" -ReportName "Sales Report") -Recipients @()
    Assert ((@($view.PSObject.Properties.Name) -join ",") -eq ($RefreshReportPlanFields -join ",")) "The report plan carries the contract fields in order"
    Assert ($view.SemanticModel -eq "Sales Model" -and @($view.UpstreamDataflows).Count -eq 3 -and $view.Email -eq "Off") "The report plan names the model, three dataflows and the email mode"
    $checks++

    # 11. A failed model keeps the service's error.
    Reset-FakeService -ModelScript @("Unknown", "Failed")
    $run = Invoke-Scenario $byName
    $model = @($run.Result.Summary.SemanticModels)[0]
    Assert ($model.status -eq "Failed" -and $model.error -match "ModelRefreshFailed") "The model error is kept"
    Assert ($run.Status.datasetStatus -eq "Failed" -and $run.Status.dataflowStatus -eq "Success") "Dataflows succeeded, the model failed"
    $checks++

    # 12. A model status that stays unreadable ends Unknown and fails the run.
    Reset-FakeService -ModelScript @("error")
    $run = Invoke-Scenario $byName
    Assert (@($run.Result.Summary.SemanticModels)[0].status -eq "Unknown" -and $run.Result.Failed) "An unreadable model ends Unknown"
    $checks++

    # 13. An exclusion that names no dataflow is an error, not a silent no-op.
    Reset-FakeService
    $run = Invoke-Scenario ($byName + @{ ExcludeDataflow = @("DF Twoo") })
    Assert ($run.Error -like "No upstream dataflow of report 'Sales Report' is named: DF Twoo*") "A misspelled exclusion is refused"
    Assert (@($script:Fake.Calls | Where-Object { $_ -like "POST *" }).Count -eq 0) "Nothing is triggered"
    $checks++

    # 14. A missing webhook is recorded, not hidden.
    Reset-FakeService -Webhook ""
    $run = Invoke-Scenario $byName
    Assert ($run.Result.Summary.EmailStatus -eq "Failed" -and $run.Result.Summary.EmailWarning -like "*not configured*") "A missing webhook is recorded"
    Assert ($run.Status.emailWarning -like "*not configured*") "The UI sees the email warning"
    $checks++

    # 15. Names that cannot be read never fall back to raw IDs.
    Reset-FakeService
    $plan = [pscustomobject]@{ WorkspaceId = $script:Ids.dfws; DataflowIds = @($script:Ids.df1); SemanticModels = @([pscustomobject]@{ WorkspaceId = $script:Ids.ws2; DatasetId = $script:Ids.model }) }
    $run = Invoke-Scenario @{ Plan = $plan; Confirmed = $true }
    Assert (@($run.Result.Summary.SemanticModels)[0].name -eq "Unnamed semantic model") "An unreadable model name is not replaced by its ID"
    Assert ($run.Log -notmatch [regex]::Escape($script:Ids.model)) "The log does not show the model ID"
    $checks++

    # 16. Model only from the Refresh tab: an ID plan with no dataflows and no dataflow
    #     workspace refreshes just the model and leaves no dataflow item in the status.
    Reset-FakeService
    $plan = [pscustomobject]@{ WorkspaceId = ""; DataflowIds = @(); SemanticModels = @([pscustomobject]@{ WorkspaceId = $script:Ids.ws; DatasetId = $script:Ids.model }) }
    $run = Invoke-Scenario @{ Plan = $plan; Confirmed = $true }
    Assert ($run.Error -eq "" -and -not $run.Result.Failed) "A model-only plan succeeds: $($run.Error)"
    Assert ((Get-PostCount "/dataflows/") -eq 0 -and (Get-PostCount "/datasets/") -eq 1) "Only the model is refreshed"
    Assert (@($run.Status.dataflowDetails).Count -eq 0 -and @($run.Status.semanticModelDetails).Count -eq 1) "The status lists the model and no dataflow"
    Assert ($run.Status.result -eq "Succeeded" -and $run.Status.datasetStatus -eq "Completed") "The status ends Succeeded"
    Assert ($run.Result.Summary.Workspace -eq "Sales TEST") "The run is labelled with the model's workspace"
    Assert ($run.Log -match "No upstream dataflows to refresh") "The log says no dataflows are refreshed"
    Assert-LocksReleased $run
    $checks++

    # 17. Dataflows in several workspaces (the catalog's lineage can return them): each
    #     Dataflows entry names its own workspace, an entry without one falls back to
    #     WorkspaceId, and the original DataflowIds form still combines with it.
    Reset-FakeService
    $plan = [pscustomobject]@{
        WorkspaceId = $script:Ids.dfws
        DataflowIds = @($script:Ids.df1)
        Dataflows = @(
            [pscustomobject]@{ WorkspaceId = $script:Ids.ws2; DataflowId = $script:Ids.df2 },
            [pscustomobject]@{ DataflowId = $script:Ids.df3 },
            [pscustomobject]@{ WorkspaceId = $script:Ids.dfws; DataflowId = $script:Ids.df1 })
        SemanticModels = @([pscustomobject]@{ WorkspaceId = $script:Ids.ws; DatasetId = $script:Ids.model })
    }
    $run = Invoke-Scenario @{ Plan = $plan; Confirmed = $true }
    Assert ($run.Error -eq "" -and -not $run.Result.Failed) "A plan with dataflows in two workspaces succeeds: $($run.Error)"
    $dataflowPosts = @($script:Fake.Calls | Where-Object { $_ -like "POST */dataflows/*" })
    Assert ($dataflowPosts.Count -eq 3) "Three dataflows are refreshed once each, the duplicate collapses (got $($dataflowPosts.Count))"
    Assert (@($dataflowPosts | Where-Object { $_ -like "*/groups/$($script:Ids.ws2)/dataflows/$($script:Ids.df2)/refreshes" }).Count -eq 1) "A dataflow is refreshed in its own workspace"
    Assert (@($dataflowPosts | Where-Object { $_ -like "*/groups/$($script:Ids.dfws)/dataflows/$($script:Ids.df3)/refreshes" }).Count -eq 1) "An entry without a workspace uses the plan's workspace"
    $other = @($run.Status.dataflowDetails | Where-Object { $_.id -eq $script:Ids.df2 })[0]
    Assert ($other.workspaceName -eq "Other") "The status names each dataflow's own workspace"
    $checks++

    # 18. -NoValidation (the validated-refresh wrapper validates on its own): no DAX query,
    #     no Validation in the summary, and the email still goes out.
    Reset-FakeService
    $run = Invoke-Scenario ($byName + @{ NoValidation = $true })
    Assert ($run.Error -eq "" -and -not $run.Result.Failed) "A run without validation succeeds: $($run.Error)"
    Assert ($script:FakeValidation.Queries.Count -eq 0) "No validation query is sent"
    Assert ($null -eq $run.Result.Summary.Validation) "The summary has no validation"
    Assert ($global:RunnerTestSent.Count -eq 1 -and $global:RunnerTestSent[0].Subject -match "Sales Report: refresh OK$") "The email has only the refresh card"
    $checks++

    # 19. A validation that cannot run never stops the refresh: the model is refreshed,
    #     the run succeeds, and the email says why the checks are missing.
    Reset-FakeService
    $script:FakeValidation.Fail = $true
    $run = Invoke-Scenario $byName
    Assert ($run.Error -eq "" -and -not $run.Result.Failed) "A failing validation does not fail the refresh: $($run.Error)"
    Assert ((Get-PostCount "/datasets/") -eq 1) "The model is still refreshed"
    Assert ($run.Result.Summary.Validation.Models[0].overall -ne "PASS") "The validation is not reported as passed (got $($run.Result.Summary.Validation.Models[0].overall))"
    Assert ($global:RunnerTestSent.Count -eq 1) "The email still goes out"
    $checks++

    # 20. A report config that matches the workspace and model is used instead of the
    #     universal checks.
    Reset-FakeService
    $savedRoot = $script:RefreshValidationRoot
    $configRoot = Join-Path $sandbox "validation-config"
    New-Item -ItemType Directory -Path (Join-Path $configRoot "reports") -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $savedRoot "universal-checks.json") -Destination $configRoot
    $salesConfig = [ordered]@{ workspaceName = "Sales TEST"; reportName = "Sales Report"; semanticModelName = "Sales Model"
        checks = @([ordered]@{ id = "sales_value"; label = "Sales value"; kind = "scalar"; query = "EVALUATE ROW(""Value"", [SalesValue])"; valueField = "Value"; format = "N0"; warnPercent = 50; failPercent = 90 }) }
    [System.IO.File]::WriteAllText((Join-Path $configRoot "reports\sales.config.json"), ($salesConfig | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
    $script:RefreshValidationRoot = $configRoot
    try { $run = Invoke-Scenario $byName } finally { $script:RefreshValidationRoot = $savedRoot }
    Assert ($run.Error -eq "" -and -not $run.Result.Failed) "A run with a report config succeeds: $($run.Error)"
    $validated = $run.Result.Summary.Validation.Models[0]
    Assert ($validated.checks -eq "sales.config.json") "The report config is chosen (got $($validated.checks))"
    Assert ($validated.overall -eq "PASS") "The config's check passes (got $($validated.overall))"
    Assert (@($script:FakeValidation.Queries | Where-Object { $_ -like "*COUNTROWS*" }).Count -eq 0) "The universal row counts are not used"
    $checks++

    # 21. A profile with two models: one validated section per model in one email.
    Reset-FakeService
    $plan = [pscustomobject]@{ WorkspaceId = ""; DataflowIds = @(); SemanticModels = @(
        [pscustomobject]@{ WorkspaceId = $script:Ids.ws; DatasetId = $script:Ids.model },
        [pscustomobject]@{ WorkspaceId = $script:Ids.ws2; DatasetId = $script:Ids.model2 }) }
    $run = Invoke-Scenario @{ Plan = $plan; Recipients = @("ops@example.com"); Confirmed = $true }
    Assert ($run.Error -eq "" -and -not $run.Result.Failed) "A two-model profile succeeds: $($run.Error)"
    Assert ((@($run.Result.Summary.Validation.Models | ForEach-Object { $_.name }) -join "|") -eq "Sales Model|Second Model") "Both models are validated"
    Assert ($global:RunnerTestSent.Count -eq 1 -and $global:RunnerTestSent[0].Subject -match "Sales Model, Second Model: refresh OK") "One email names both models: $($global:RunnerTestSent[0].Subject)"
    $body = $global:RunnerTestSent[0].HtmlBody
    Assert ($body -match "Sales Model" -and $body -match "Second Model") "Each model has its own section"
    $checks++

    # 22. Another refresh of the model starts while the dataflows run (idle at the start,
    #     busy when the model is due): the run waits and then starts its own refresh.
    Reset-FakeService -BusySteps @($false, $true, $true, $false)
    $run = Invoke-Scenario $byName
    Assert ($run.Error -eq "" -and -not $run.Result.Failed) "A run that waits for another refresh succeeds: $($run.Error)"
    Assert ((Get-PostCount "/datasets/") -eq 1) "This run's refresh is started once, after the other one"
    Assert ($run.Log -match "another refresh, not started by this run, is in progress; waiting") "The wait is logged"
    Assert ($run.Log -match "the other refresh has finished; starting this run's refresh") "The end of the wait is logged"
    Assert (@([regex]::Matches($run.Log, "is in progress; waiting")).Count -eq 1) "The wait is logged once, not on every poll"
    $checks++

    # 23. The race seen on 2026-11-19: the request is refused while another refresh runs
    #     and that one ends a moment later. The run tries again and succeeds.
    Reset-FakeService -RefusePosts 1
    $run = Invoke-Scenario $byName
    Assert ($run.Error -eq "" -and -not $run.Result.Failed) "A refused request is retried after the other refresh: $($run.Error)"
    Assert ((Get-PostCount "/datasets/") -eq 2) "The refresh is requested twice"
    Assert ($run.Log -match "refused while another refresh was running \(The remote server returned an error: \(400\) Bad Request\. InvalidRequest: Another refresh request is already executing\)") "The log carries the service's reason"
    $checks++

    # 24. Refused again and again: Failed after the limit, with the service's reason.
    Reset-FakeService -RefusePosts 5
    $run = Invoke-Scenario $byName
    $model = @($run.Result.Summary.SemanticModels)[0]
    Assert ($run.Result.Failed -and $model.status -eq "Failed") "Repeated refusals fail the model"
    Assert ((Get-PostCount "/datasets/") -eq $script:RefreshModelRefusalLimit) "No more than $($script:RefreshModelRefusalLimit) requests are sent"
    Assert ($model.error -like "Refused 3 times while other refreshes of this model were running; last reason: *Another refresh request is already executing*") "The error explains the refusals: $($model.error)"
    $checks++

    # 25. A refusal with no other refresh is not retried, and keeps the service's reason.
    Reset-FakeService -RefusePosts 1 -RefuseWithoutOther $true
    $run = Invoke-Scenario $byName
    $model = @($run.Result.Summary.SemanticModels)[0]
    Assert ($model.status -eq "Failed" -and (Get-PostCount "/datasets/") -eq 1) "An unexplained refusal fails at once"
    Assert ($model.error -like "*(400) Bad Request. InvalidRequest: Another refresh request is already executing") "The error keeps the service's reason: $($model.error)"
    Assert ($global:RunnerTestSent[0].HtmlBody -match "InvalidRequest") "The email shows the reason"
    $checks++
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

# The entry script, started the way the Control Panel starts it, records why it stopped
# in -ErrorLogPath and exits 1. The arguments conflict, so it stops before signing in.
$errorSandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("runner-errorlog-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $errorSandbox | Out-Null
try {
    $errorLog = Join-Path $errorSandbox "refresh-worker-errors.log"
    $planText = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('{"WorkspaceId":"","DataflowIds":[],"SemanticModels":[]}'))
    # Under Stop, Windows PowerShell 5.1 turns the child's stderr into a terminating error.
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "runtime\Invoke-RefreshRun.ps1") -WorkspaceName "Sales TEST" -PlanBase64 $planText -ErrorLogPath $errorLog -Confirmed 2>&1 | Out-Null
        $childExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    Assert ($childExit -eq 1) "A runner that cannot start exits 1"
    Assert ((Test-Path -LiteralPath $errorLog) -and ([System.IO.File]::ReadAllText($errorLog) -match "not both")) "The reason is written to the error log"
} finally {
    Remove-Item -LiteralPath $errorSandbox -Recurse -Force -ErrorAction SilentlyContinue
}
$checks++

# The entry script parses and stays ASCII-only.
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot "runtime") -Filter *.ps1) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) "$($file.Name) must parse"
    Assert (@([System.IO.File]::ReadAllBytes($file.FullName) | Where-Object { $_ -gt 127 }).Count -eq 0) "$($file.Name) must be ASCII-only"
}
$checks++

Write-Host "Runner tests OK ($checks checks)"
