# Interfaces that every refresh producer must keep while the refresh code converges
# into one runner.
# Dot-sourced by _refresh-contract-tests.ps1 and, later, by the runner tests, so the
# old producers and the new runner are checked against the same lists.

# refresh-status.json: written by server.ps1 and the refresh worker, polled by the
# Refresh tab (index.html pollStatus).
$RefreshStatusFields = @(
    "running", "result", "startTime", "endTime", "durationSeconds", "logs",
    "dataflowStatus", "datasetStatus", "dataflowDetails", "semanticModelDetails",
    "emailStatus", "emailWarning", "error"
)
# Fields the worker sets when it finishes; the UI decides the outcome from them.
$RefreshStatusFinalFields = @(
    "running", "result", "endTime", "durationSeconds", "dataflowDetails",
    "semanticModelDetails", "dataflowStatus", "datasetStatus", "error"
)
# One entry of "logs". The UI colours a line by the words ERROR, FAILED, completed,
# SUCCESS and WARNING in its text.
$RefreshLogEntryFields = @("time", "text")
# Fields of one semanticModelDetails entry that the UI renders.
$RefreshModelDetailUiFields = @("id", "name", "workspaceId", "workspaceName", "status", "error")
# Final values the UI understands. "result" is Succeeded or Failed; the dots turn
# green on Success/Succeeded/Completed and red on Failure/Failed/Cancelled/Disabled.
$RefreshStatusResults = @("Succeeded", "Failed")
$RefreshStatusDataflowFinal = @("Success", "Failed")
$RefreshStatusModelFinal = @("Completed", "Failed", "Skipped")

# summary.json: written by the skill's invoke-refresh-report.ps1 into
# %LOCALAPPDATA%\PowerBIChainedRefresh\runs\<run>\ and read by the validated
# refresh wrapper (Find-ValidationChainRun, New-ValidationEmailContent and the run
# summary read Workspace, Report, Result, StartedAt, ExcludedDataflows, Dataflows
# and SemanticModels).
$RefreshSummaryFields = @(
    "Workspace", "Report", "SemanticModel", "Result", "StartedAt", "EndedAt",
    "DurationSeconds", "Dataflows", "ExcludedDataflows", "SemanticModels", "Validation",
    "EmailStatus", "EmailWarning", "Recipients", "Authentication", "Artifacts"
)
# The skill's built-in engine (only used with a Control Panel checkout older than
# runtime\) predates the validation stage, so its summary has no Validation field.
$RefreshSummaryFieldsWithoutValidation = @($RefreshSummaryFields | Where-Object { $_ -ne "Validation" })
$RefreshSummaryItemFields = @("workspaceName", "name", "status", "error", "completedAt")
# The wrapper recognises a run that wrote no summary by the first line of its
# refresh-log.txt (after the time stamp): Starting report '<report>' in workspace '<workspace>'.
$RefreshLogFirstLinePattern = "Starting report '{0}' in workspace '{1}'."
# The read-only plan printed for a report without -Confirmed, in this order: by the
# skill's invoke-refresh-report.ps1 before 1.7.0 and by the runner since.
$RefreshReportPlanFields = @(
    "Workspace", "Report", "SemanticModel", "UpstreamDataflows", "ExcludedDataflows",
    "Recipients", "Email", "Authentication"
)

# Refresh items as the email builder (New-ValidationEmailContent) lists them.
$RefreshEmailItemFields = @("Type", "Name", "WorkspaceName", "Status", "Error", "CompletedAt")
