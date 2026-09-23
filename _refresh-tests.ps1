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

. (Join-Path $PSScriptRoot "refresh-email.ps1")
$items = @(
    [pscustomobject]@{ Type = "Dataflow"; Name = "Orders & Sales"; WorkspaceName = "Finance"; Status = "Succeeded"; Error = "" },
    [pscustomobject]@{ Type = "Semantic model"; Name = "Executive"; WorkspaceName = "Finance"; Status = "Succeeded"; Error = "" }
)
$email = Get-RefreshEmailContent -Items $items -StartTime ([datetime]"2026-09-21T10:00:00") -EndTime ([datetime]"2026-09-21T10:05:30")
Assert ($email.Subject -match "2 items") "Success subject should include the item count"
Assert ($email.HtmlBody -match "Orders &amp; Sales") "HTML values should be encoded"
Assert ($email.HtmlBody -match "05:30") "HTML should include total duration"

$failedItems = @([pscustomobject]@{ Type = "Semantic model"; Name = "Model"; WorkspaceName = "Workspace"; Status = "Failed"; Error = "Short failure" })
$failedEmail = Get-RefreshEmailContent -Items $failedItems -StartTime (Get-Date).AddMinutes(-1) -EndTime (Get-Date)
Assert $failedEmail.HasErrors "Failed item should mark the email as an error outcome"
Assert ($failedEmail.Subject -match "with errors") "Failure subject should make the outcome obvious"
Assert ($failedEmail.HtmlBody -match "Short failure") "Failure message should appear in the body"

$template = Get-Content -LiteralPath (Join-Path $PSScriptRoot "_refresh-worker-template.ps1") -Raw
$testPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"WorkspaceId":"00000000-0000-0000-0000-000000000000","DataflowIds":[],"SemanticModels":[],"NotificationRecipients":[],"EmailDryRun":true}'))
$generated = $template.Replace("{{StatusFile}}", "C:\temp\status.json").Replace("{{LogsDir}}", "C:\temp\logs").Replace("{{EmailModule}}", "C:\temp\refresh-email.ps1").Replace("{{Token}}", "test-token").Replace("{{RefreshPayload}}", $testPayload)
Assert ($generated -notmatch '\{\{') "Generated worker should not contain unresolved placeholders"
$workerTokens = $null
$workerErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($generated, [ref]$workerTokens, [ref]$workerErrors)
Assert ($workerErrors.Count -eq 0) "Generated worker should parse"
Assert ($template -match 'Where-Object \{ -not \(Test-TerminalModelStatus') "Worker should continue polling non-terminal semantic models"
Assert ($template -match 'Complete-Notification') "Worker should run one final notification step"
Assert ($serverSource -notmatch 'graph\.microsoft\.com') "Graph must not be introduced into the Power BI token path"

Write-Host "Refresh contract tests OK"
