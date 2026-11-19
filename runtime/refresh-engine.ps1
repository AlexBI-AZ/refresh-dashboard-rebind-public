# Refresh engine: sign-in, discovery, the dataflow -> semantic model chain, the
# notification, the run summary and the optional live status file.
#
# Invoke-RefreshRun.ps1 is the command-line entry point; the tests dot-source this
# file and replace the HTTP functions with fakes. The behaviour follows the skill's
# runner (invoke-refresh-report.ps1): an unreadable status is retried and, past the
# budget, reported as Unknown rather than Failed; a 404 never starts a second
# refresh; a refresh accepted without a status location is followed through the
# refresh history.
#
# Windows PowerShell 5.1. Keep this file ASCII-only.

. (Join-Path $PSScriptRoot "refresh-core.ps1")

# The validation stage of every run (before and after snapshots of each semantic model,
# their comparison, and the one email) lives in validation\validation.ps1 next to
# runtime\. A model with a report config in validation\reports gets its checks; any
# other model gets the universal checks in validation\universal-checks.json.
$script:RefreshValidationRoot = Join-Path (Split-Path -Parent $PSScriptRoot) "validation"
. (Join-Path $script:RefreshValidationRoot "validation.ps1")

# Settings. Tests shorten the poll interval and budgets.
$script:RefreshPollSeconds = 30
$script:RefreshBudgetHours = 11
# Consecutive unreadable status reads tolerated before an item is reported Unknown.
# At the 30-second poll this is about ten minutes: a dropped VPN or a brief service
# hiccup is not a refresh result.
$script:RefreshUnreadableLimit = 20
# Model refresh requests refused while another refresh of the model was running,
# tolerated before the model is reported Failed (each one is waited out first).
$script:RefreshModelRefusalLimit = 3
$script:RefreshTokenRenewal = [TimeSpan]::FromMinutes(45)
# After a failed scheduled renewal the current token is kept and renewal is tried
# again after this interval; the token is still valid for a while.
$script:RefreshRenewalRetry = [TimeSpan]::FromMinutes(5)
$script:RefreshQuiet = $false

$script:RefreshAuthContext = $null
$script:RefreshHeaders = $null
$script:RefreshTokenAcquiredAt = [datetime]::MinValue
$script:RefreshAuthMode = ""
$script:RefreshLogFile = $null
$script:RefreshStatusFile = $null
$script:RefreshWorkspaceNames = @{}

# --- logging and the live status file -----------------------------------------------

function Update-RefreshStatusFile {
    # Read, change and rewrite the status file the Control Panel polls. Written as
    # UTF-8 with a byte order mark, so Windows PowerShell 5.1's Get-Content in
    # server.ps1 decodes non-ASCII names correctly. Never throws.
    param([scriptblock]$Update)

    if ([string]::IsNullOrWhiteSpace($script:RefreshStatusFile)) { return }
    try {
        $state = [System.IO.File]::ReadAllText($script:RefreshStatusFile) | ConvertFrom-Json
        & $Update $state
        $json = $state | ConvertTo-Json -Depth 10 -Compress
        [System.IO.File]::WriteAllText($script:RefreshStatusFile, $json, (New-Object System.Text.UTF8Encoding($true)))
    } catch { }
}

function Initialize-RefreshStatusFile {
    param([datetime]$StartedAt, [bool]$EmailRequested)

    if ([string]::IsNullOrWhiteSpace($script:RefreshStatusFile)) { return }
    $state = [ordered]@{
        running = $true
        result = "Running"
        startTime = $StartedAt.ToString("o")
        endTime = ""
        durationSeconds = 0
        logs = @()
        dataflowStatus = "Pending"
        datasetStatus = "Pending"
        dataflowDetails = @()
        semanticModelDetails = @()
        emailStatus = if ($EmailRequested) { "Pending" } else { "Skipped" }
        emailWarning = ""
        error = ""
    }
    try {
        $json = $state | ConvertTo-Json -Depth 10 -Compress
        [System.IO.File]::WriteAllText($script:RefreshStatusFile, $json, (New-Object System.Text.UTF8Encoding($true)))
    } catch { }
}

function Write-RefreshLog {
    param([string]$Message)

    $now = Get-Date
    $line = "$($now.ToString('yyyy-MM-dd HH:mm:ss')) | $Message"
    if (-not $script:RefreshQuiet) { Write-Host $line }
    if ($script:RefreshLogFile) {
        try { [System.IO.File]::AppendAllText($script:RefreshLogFile, $line + [Environment]::NewLine) } catch { }
    }
    if ($script:RefreshStatusFile) {
        $entry = [pscustomobject]@{ time = $now.ToString("HH:mm:ss"); text = $Message }
        Update-RefreshStatusFile { param($state) $state.logs = @(@($state.logs) + $entry) }
    }
}

function Get-RefreshDataflowPhaseText {
    param([object[]]$Dataflows)

    $succeeded = @($Dataflows | Where-Object { $_.status -eq "Succeeded" }).Count
    $failed = @($Dataflows | Where-Object { $_.status -in @("Failed", "Unknown") }).Count
    return "Running ($succeeded/$(@($Dataflows).Count); $failed failed)"
}

function Get-RefreshFinalDataflowStatus {
    # The Control Panel knows Success and Failed. An unverified (Unknown) dataflow
    # is not a success, so its dot turns red; the row itself still says Unknown.
    param([object[]]$Dataflows)

    if (@($Dataflows | Where-Object { $_.status -ne "Succeeded" }).Count -gt 0) { return "Failed" }
    return "Success"
}

function Get-RefreshFinalModelStatus {
    param([object[]]$Models)

    if (@($Models | Where-Object { $_.status -in @("Failed", "Unknown") }).Count -gt 0) { return "Failed" }
    if (@($Models | Where-Object { $_.status -eq "Skipped" }).Count -gt 0) { return "Skipped" }
    return "Completed"
}

function Publish-RefreshStatus {
    param(
        [AllowNull()][string]$DataflowStatus,
        [AllowNull()][string]$DatasetStatus,
        [object[]]$Dataflows,
        [object[]]$Models
    )

    if ([string]::IsNullOrWhiteSpace($script:RefreshStatusFile)) { return }
    $dataflowCopy = @($Dataflows)
    $modelCopy = @($Models)
    Update-RefreshStatusFile {
        param($state)
        if ($DataflowStatus) { $state.dataflowStatus = $DataflowStatus }
        if ($DatasetStatus) { $state.datasetStatus = $DatasetStatus }
        $state.dataflowDetails = $dataflowCopy
        $state.semanticModelDetails = $modelCopy
    }
}

# --- authorization ------------------------------------------------------------------------

function Set-RefreshAuthorization {
    # Builds the authentication context once per run, then renews through the
    # shared module (a silent certificate request or a silent MSAL-cache hit).
    param([switch]$ForceRefresh, [string]$Reason = "initial sign-in")

    if ($null -eq $script:RefreshAuthContext) { $script:RefreshAuthContext = New-PowerBiAuthContext }
    $token = Get-PowerBiAccessToken -Context $script:RefreshAuthContext -ForceRefresh:$ForceRefresh
    $script:RefreshHeaders = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
    $script:RefreshTokenAcquiredAt = Get-Date
    $script:RefreshAuthMode = [string]$script:RefreshAuthContext.Mode
    if ($ForceRefresh) { Write-RefreshLog "Power BI authorization renewed ($Reason) using $($script:RefreshAuthMode) authentication." }
}

function Initialize-RefreshAuthorization {
    # The Control Panel signs in and hands over that token, with the mode it used
    # (service-principal or delegated); it is used until the first renewal, which
    # goes through powerbi-auth.ps1 like every other renewal.
    param([AllowNull()][string]$InitialToken, [AllowNull()][string]$InitialMode)

    if (-not [string]::IsNullOrWhiteSpace($InitialToken)) {
        $script:RefreshHeaders = @{ Authorization = "Bearer $InitialToken"; "Content-Type" = "application/json" }
        $script:RefreshTokenAcquiredAt = Get-Date
        $modeText = if ([string]::IsNullOrWhiteSpace($InitialMode)) { "unknown mode" } else { $InitialMode.Trim() }
        $script:RefreshAuthMode = "$modeText (Control Panel sign-in)"
        return
    }
    Set-RefreshAuthorization
}

function Confirm-RefreshAuthorization {
    # Scheduled renewal. When it fails and a token is still held, keep using it and
    # try again a few minutes later instead of failing the run.
    if ($null -ne $script:RefreshHeaders -and ((Get-Date) - $script:RefreshTokenAcquiredAt) -lt $script:RefreshTokenRenewal) { return }
    try {
        Set-RefreshAuthorization -ForceRefresh -Reason "scheduled token renewal"
    } catch {
        if ($null -eq $script:RefreshHeaders) { throw }
        Write-RefreshLog "WARNING: Scheduled token renewal failed; keeping the current token for now: $(Get-RefreshShortError $_)"
        $script:RefreshTokenAcquiredAt = (Get-Date) - $script:RefreshTokenRenewal + $script:RefreshRenewalRetry
    }
}

function Throw-RefreshRejectedAuthorization {
    throw "Power BI rejected authorization even after silent renewal. Your Microsoft Entra session may have been revoked by policy, or the account may no longer have access. Sign in again (connect-powerbi-refresh.ps1 or the Control Panel's Authenticate button). If it continues, ask the Power BI administrator to verify the account's workspace access."
}

function Invoke-PowerBiRequest {
    param(
        [ValidateSet("GET", "POST")][string]$Method,
        [string]$Uri,
        [AllowNull()][string]$Body
    )

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        Confirm-RefreshAuthorization
        $request = @{ Method = $Method; Uri = $Uri; Headers = $script:RefreshHeaders; ErrorAction = "Stop" }
        if (-not [string]::IsNullOrEmpty($Body)) { $request.Body = $Body }
        try {
            return Invoke-RestMethod @request
        } catch {
            if ((Get-RefreshHttpStatusCode $_) -eq 401 -and $attempt -eq 0) {
                Set-RefreshAuthorization -ForceRefresh -Reason "an unauthorized Power BI response"
                continue
            }
            if ((Get-RefreshHttpStatusCode $_) -eq 401) { Throw-RefreshRejectedAuthorization }
            throw
        }
    }
}

function Invoke-PowerBiWebRequest {
    param(
        [ValidateSet("GET", "POST")][string]$Method,
        [string]$Uri,
        [AllowNull()][string]$Body
    )

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        Confirm-RefreshAuthorization
        $request = @{ Method = $Method; Uri = $Uri; Headers = $script:RefreshHeaders; UseBasicParsing = $true; ErrorAction = "Stop" }
        if (-not [string]::IsNullOrEmpty($Body)) { $request.Body = $Body }
        try {
            return Invoke-WebRequest @request
        } catch {
            if ((Get-RefreshHttpStatusCode $_) -eq 401 -and $attempt -eq 0) {
                Set-RefreshAuthorization -ForceRefresh -Reason "an unauthorized Power BI response"
                continue
            }
            if ((Get-RefreshHttpStatusCode $_) -eq 401) { Throw-RefreshRejectedAuthorization }
            throw
        }
    }
}

function Wait-RefreshPollInterval {
    Start-Sleep -Seconds $script:RefreshPollSeconds
}

function Get-RefreshRequestError {
    # The error of a refused request with the service's own message. Windows
    # PowerShell puts only the status line ("(400) Bad Request") in the exception;
    # the reason (for example another refresh in progress) is in the response body.
    param([Parameter(Mandatory = $true)][object]$ErrorRecord)

    $message = [string]$ErrorRecord.Exception.Message
    $body = ""
    if ($null -ne $ErrorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.ErrorDetails.Message)) {
        $body = [string]$ErrorRecord.ErrorDetails.Message
    } else {
        try {
            $response = $ErrorRecord.Exception.Response
            if ($null -ne $response) {
                $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
                $body = $reader.ReadToEnd()
                $reader.Dispose()
            }
        } catch { }
    }
    $detail = ""
    if (-not [string]::IsNullOrWhiteSpace($body)) {
        $detail = $body
        try {
            $parsed = $body | ConvertFrom-Json -ErrorAction Stop
            $serviceError = $parsed.error
            if ($null -ne $serviceError) {
                $parts = @(@([string]$serviceError.code, [string]$serviceError.message) | Where-Object { $_ })
                if ($null -ne $serviceError.PSObject.Properties["pbi.error"]) { $parts += [string]$serviceError."pbi.error".code }
                if ($parts.Count -gt 0) { $detail = ($parts | Select-Object -Unique) -join ": " }
            }
        } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($detail) -or $message.Contains($detail)) { return Get-RefreshShortError $message }
    return Get-RefreshShortError "$message $detail"
}

# --- discovery ------------------------------------------------------------------------------

$script:PowerBiApi = "https://api.powerbi.com/v1.0/myorg"

function Assert-RefreshGuid {
    param([string]$Value, [string]$Description)

    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParse($Value, [ref]$parsed)) { throw "$Description is not a valid Power BI identifier." }
}

function Test-RefreshAuthorizationError {
    param($ErrorRecord)
    return ([string]$ErrorRecord.Exception.Message) -like "Power BI rejected authorization*"
}

function Select-RefreshExactMatch {
    param([object[]]$Items, [string]$RequestedName, [string]$Kind)

    $found = @($Items | Where-Object { ([string]$_.name).Trim() -ieq $RequestedName.Trim() })
    if ($found.Count -eq 1) { return $found[0] }

    $available = @($Items | ForEach-Object { ([string]$_.name).Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    $availableText = if ($available.Count -gt 0) { $available -join "; " } else { "none" }
    if ($found.Count -eq 0) {
        throw "No accessible $Kind exactly named '$RequestedName' was found. Available $($Kind)s: $availableText"
    }
    throw "More than one accessible $Kind is named '$RequestedName'. Please select a unique $Kind. Candidates: $availableText"
}

function Get-RefreshWorkspaceLabel {
    param([string]$WorkspaceId)

    if ($script:RefreshWorkspaceNames.ContainsKey($WorkspaceId)) { return $script:RefreshWorkspaceNames[$WorkspaceId] }
    try {
        $group = Invoke-PowerBiRequest -Method GET -Uri "$script:PowerBiApi/groups/$WorkspaceId"
        $label = ([string]$group.name).Trim()
        if (-not $label) { $label = "Unnamed workspace" }
    } catch {
        if (Test-RefreshAuthorizationError $_) { throw }
        $label = "Workspace name unavailable"
        Write-RefreshLog "WARNING: Could not resolve a workspace name: $(Get-RefreshShortError $_)"
    }
    $script:RefreshWorkspaceNames[$WorkspaceId] = $label
    return $label
}

function Get-RefreshItemLabel {
    # Name of a dataflow or semantic model. Never falls back to the raw ID, which
    # would otherwise reach the email and the logs.
    param([string]$WorkspaceId, [string]$ItemId, [ValidateSet("dataflows", "datasets")][string]$Collection)

    $fallback = if ($Collection -eq "dataflows") { "Unnamed dataflow" } else { "Unnamed semantic model" }
    try {
        $item = Invoke-PowerBiRequest -Method GET -Uri "$script:PowerBiApi/groups/$WorkspaceId/$Collection/$ItemId"
        $label = ([string]$item.name).Trim()
        if ($label) { return $label }
    } catch {
        if (Test-RefreshAuthorizationError $_) { throw }
        Write-RefreshLog "WARNING: Could not resolve a name ($fallback): $(Get-RefreshShortError $_)"
    }
    return $fallback
}

function New-RefreshDataflowItem {
    param([string]$Id, [string]$WorkspaceId, [string]$WorkspaceName, [string]$Name)

    # Every field is declared up front: [pscustomobject] rejects properties added later.
    return [pscustomobject][ordered]@{
        id = $Id
        workspaceId = $WorkspaceId
        workspaceName = $WorkspaceName
        name = $Name
        triggeredAt = ""
        completedAt = ""
        status = "Pending"
        error = ""
        unreadableCount = 0
    }
}

function New-RefreshModelItem {
    param([string]$Id, [string]$WorkspaceId, [string]$WorkspaceName, [string]$Name)

    return [pscustomobject][ordered]@{
        id = $Id
        workspaceId = $WorkspaceId
        workspaceName = $WorkspaceName
        name = $Name
        requestId = ""
        triggeredAt = ""
        completedAt = ""
        status = "Pending"
        error = ""
        unreadableCount = 0
    }
}

function Get-RefreshUpstreamDataflowLinks {
    # The dataflows a semantic model reads from, from lineage: the workspace-level
    # upstreamDataflows list (read in -LineageWorkspaceId), or the model's own
    # upstreamDataflows when that list cannot be read. Returns unique
    # {WorkspaceId, DataflowId} pairs; the dataflows may live in any workspace.
    # Shared by the runner's name discovery and the Control Panel's catalog. Read-only.
    param(
        [Parameter(Mandatory = $true)][string]$LineageWorkspaceId,
        [Parameter(Mandatory = $true)][string]$DatasetId,
        [AllowNull()][object]$Model
    )

    $links = $null
    try {
        $allWorkspaceLinks = @(Invoke-PowerBiRequest -Method GET -Uri "$script:PowerBiApi/groups/$LineageWorkspaceId/datasets/upstreamDataflows").value
        $links = @(
            $allWorkspaceLinks |
                Where-Object { [string]$_.datasetObjectId -eq $DatasetId } |
                ForEach-Object { [pscustomobject]@{ WorkspaceId = [string]$_.workspaceObjectId; DataflowId = [string]$_.dataflowObjectId } }
        )
    } catch {
        if (Test-RefreshAuthorizationError $_) { throw }
        if ($null -ne $Model -and @($Model.PSObject.Properties.Name) -contains "upstreamDataflows") {
            $links = @(
                @($Model.upstreamDataflows) |
                    Where-Object { $null -ne $_ } |
                    ForEach-Object { [pscustomobject]@{ WorkspaceId = [string]$_.groupId; DataflowId = [string]$_.targetDataflowId } }
            )
        } else {
            throw "Power BI did not return dataflow lineage for this semantic model, and the workspace-level lineage endpoint could not be read. No refresh plan was generated."
        }
    }

    $unique = @()
    $seen = @{}
    foreach ($link in $links) {
        if ([string]::IsNullOrWhiteSpace($link.WorkspaceId) -or [string]::IsNullOrWhiteSpace($link.DataflowId)) { continue }
        $key = "$($link.WorkspaceId)/$($link.DataflowId)".ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $unique += $link
    }
    return $unique
}

function Resolve-RefreshPlanByName {
    # Workspace and report names -> the report's semantic model and its upstream
    # dataflows (from lineage, in any workspace). Read-only.
    param([string]$WorkspaceName, [string]$ReportName)

    $workspaces = @((Invoke-PowerBiRequest -Method GET -Uri "$script:PowerBiApi/groups").value)
    $workspace = Select-RefreshExactMatch -Items $workspaces -RequestedName $WorkspaceName -Kind "workspace"
    $script:RefreshWorkspaceNames[[string]$workspace.id] = [string]$workspace.name
    $reports = @((Invoke-PowerBiRequest -Method GET -Uri "$script:PowerBiApi/groups/$($workspace.id)/reports").value)
    $report = Select-RefreshExactMatch -Items $reports -RequestedName $ReportName -Kind "report"
    $datasetId = [string]$report.datasetId
    Assert-RefreshGuid $datasetId "The selected report's semantic model"

    $modelCandidates = @()
    foreach ($candidateWorkspace in $workspaces) {
        try {
            $candidate = Invoke-PowerBiRequest -Method GET -Uri "$script:PowerBiApi/groups/$($candidateWorkspace.id)/datasets/$datasetId"
            if ($candidate) { $modelCandidates += [pscustomobject]@{ Workspace = $candidateWorkspace; Dataset = $candidate } }
        } catch {
            if (Test-RefreshAuthorizationError $_) { throw }
        }
    }
    if ($modelCandidates.Count -eq 0) {
        throw "The selected report's semantic model could not be read in an accessible workspace. The signed-in account needs dataset read access for report discovery."
    }
    if ($modelCandidates.Count -gt 1) {
        $candidateNames = @($modelCandidates | ForEach-Object { [string]$_.Workspace.name } | Sort-Object -Unique) -join "; "
        throw "The selected report's semantic model was found in multiple accessible workspaces. Please select the semantic-model workspace: $candidateNames"
    }
    $modelWorkspace = $modelCandidates[0].Workspace
    $model = $modelCandidates[0].Dataset
    $script:RefreshWorkspaceNames[[string]$modelWorkspace.id] = [string]$modelWorkspace.name
    if ($model.PSObject.Properties.Name -contains "isRefreshable" -and -not [bool]$model.isRefreshable) {
        throw "The semantic model for report '$($report.name)' is not refreshable (for example, it may use DirectQuery or a live connection). No refresh was started."
    }

    $dataflows = @(
        foreach ($link in @(Get-RefreshUpstreamDataflowLinks -LineageWorkspaceId ([string]$workspace.id) -DatasetId $datasetId -Model $model)) {
            New-RefreshDataflowItem -Id $link.DataflowId -WorkspaceId $link.WorkspaceId -WorkspaceName (Get-RefreshWorkspaceLabel $link.WorkspaceId) -Name (Get-RefreshItemLabel $link.WorkspaceId $link.DataflowId "dataflows")
        }
    )

    $modelName = if ([string]::IsNullOrWhiteSpace([string]$model.name)) { "Unnamed semantic model" } else { [string]$model.name }
    return [pscustomobject]@{
        Kind = "report"
        Workspace = [string]$workspace.name
        Report = [string]$report.name
        Dataflows = @($dataflows)
        Models = @(New-RefreshModelItem -Id $datasetId -WorkspaceId ([string]$modelWorkspace.id) -WorkspaceName ([string]$modelWorkspace.name) -Name $modelName)
        Excluded = @()
    }
}

function Resolve-RefreshPlanByIds {
    # A Control Panel profile, all by ID: dataflows and any number of semantic models,
    # each in any workspace. Names are looked up for display. Dataflows come as
    # DataflowIds (all in WorkspaceId, the original form) and/or as Dataflows, a list of
    # {WorkspaceId, DataflowId} where each names its own workspace (WorkspaceId is the
    # fallback when an entry has none). Both forms may be combined; duplicates collapse.
    param([Parameter(Mandatory = $true)][object]$Plan)

    $workspaceId = ([string]$Plan.WorkspaceId).Trim()
    $dataflowEntries = @()
    foreach ($id in @(@($Plan.DataflowIds) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })) {
        $dataflowEntries += [pscustomobject]@{ WorkspaceId = $workspaceId; DataflowId = $id }
    }
    foreach ($entry in @(@($Plan.Dataflows) | Where-Object { $null -ne $_ })) {
        $entryWorkspaceId = if ($entry.WorkspaceId) { ([string]$entry.WorkspaceId).Trim() } else { $workspaceId }
        $dataflowEntries += [pscustomobject]@{ WorkspaceId = $entryWorkspaceId; DataflowId = ([string]$entry.DataflowId).Trim() }
    }
    $modelEntries = @(@($Plan.SemanticModels) | Where-Object { $null -ne $_ })
    if ($dataflowEntries.Count -eq 0 -and $modelEntries.Count -eq 0) { throw "The refresh plan names no dataflows and no semantic models." }

    $dataflows = @()
    $seenDataflows = @{}
    foreach ($entry in $dataflowEntries) {
        Assert-RefreshGuid $entry.WorkspaceId "The dataflow workspace"
        Assert-RefreshGuid $entry.DataflowId "A dataflow"
        $key = "$($entry.WorkspaceId)|$($entry.DataflowId)".ToLowerInvariant()
        if ($seenDataflows.ContainsKey($key)) { continue }
        $seenDataflows[$key] = $true
        $dataflows += New-RefreshDataflowItem -Id $entry.DataflowId -WorkspaceId $entry.WorkspaceId -WorkspaceName (Get-RefreshWorkspaceLabel $entry.WorkspaceId) -Name (Get-RefreshItemLabel $entry.WorkspaceId $entry.DataflowId "dataflows")
    }
    $models = @()
    $seen = @{}
    foreach ($entry in $modelEntries) {
        $modelWorkspaceId = if ($entry.WorkspaceId) { ([string]$entry.WorkspaceId).Trim() } else { $workspaceId }
        $datasetId = ([string]$entry.DatasetId).Trim()
        Assert-RefreshGuid $modelWorkspaceId "A semantic model workspace"
        Assert-RefreshGuid $datasetId "A semantic model"
        $key = "$modelWorkspaceId|$datasetId".ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $models += New-RefreshModelItem -Id $datasetId -WorkspaceId $modelWorkspaceId -WorkspaceName (Get-RefreshWorkspaceLabel $modelWorkspaceId) -Name (Get-RefreshItemLabel $modelWorkspaceId $datasetId "datasets")
    }

    $label = if ($dataflows.Count -gt 0) { $dataflows[0].workspaceName } else { $models[0].workspaceName }
    return [pscustomobject]@{
        Kind = "profile"
        Workspace = $label
        Report = ""
        Dataflows = @($dataflows)
        Models = @($models)
        Excluded = @()
    }
}

function Set-RefreshPlanExclusions {
    # Removes upstream dataflows the caller asked to leave alone, by exact name.
    # A name that matches no dataflow is an error, never a silent no-op. Several
    # names may arrive in one argument (powershell.exe -File binds a list once), so
    # values are split on commas and semicolons unless they already name a dataflow.
    param([Parameter(Mandatory = $true)][object]$Plan, [AllowNull()][string[]]$ExcludeDataflow)

    if (@($ExcludeDataflow | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) { return $Plan }
    $availableNames = @($Plan.Dataflows | ForEach-Object { $_.name } | Sort-Object -Unique)
    $requested = @()
    foreach ($value in @($ExcludeDataflow)) {
        $text = ([string]$value).Trim()
        if (-not $text) { continue }
        if (@($availableNames | Where-Object { $_ -ieq $text }).Count -gt 0) { $requested += $text; continue }
        foreach ($part in ($text -split '[,;]')) { if ($part.Trim()) { $requested += $part.Trim() } }
    }
    $requested = @($requested | Select-Object -Unique)
    $unknown = @($requested | Where-Object { $name = $_; @($availableNames | Where-Object { $_ -ieq $name }).Count -eq 0 })
    if ($unknown.Count -gt 0) {
        $availableText = if ($availableNames.Count -gt 0) { $availableNames -join "; " } else { "none" }
        $owner = if ($Plan.Report) { "report '$($Plan.Report)'" } else { "this refresh plan" }
        throw "No upstream dataflow of $owner is named: $($unknown -join '; '). Available upstream dataflows: $availableText"
    }
    $kept = @()
    $excluded = @()
    foreach ($item in $Plan.Dataflows) {
        if (@($requested | Where-Object { $_ -ieq $item.name }).Count -gt 0) { $excluded += [string]$item.name } else { $kept += $item }
    }
    $Plan.Dataflows = @($kept)
    $Plan.Excluded = @($excluded)
    return $Plan
}

function Test-RefreshModelBusy {
    # True when the service reports a refresh of this model still in progress (its
    # newest history row has status "Unknown"). A history that cannot be read does
    # not block the run; it is logged.
    param([Parameter(Mandatory = $true)][object]$Model)

    try {
        $history = Invoke-PowerBiRequest -Method GET -Uri "$script:PowerBiApi/groups/$($Model.workspaceId)/datasets/$($Model.id)/refreshes?`$top=1"
        $latest = @($history.value) | Select-Object -First 1
        return ($null -ne $latest -and [string]$latest.status -eq "Unknown")
    } catch {
        if (Test-RefreshAuthorizationError $_) { throw }
        Write-RefreshLog "WARNING: Could not read the refresh history of '$($Model.name)' before starting: $(Get-RefreshShortError $_)"
        return $false
    }
}

function Get-RefreshModelActivity {
    # What the service's newest history row says about refreshes started elsewhere:
    # "Busy" while one is in progress, "FinishedSince" when one ended at or after
    # -Since (it was running when a request was refused), "Idle" otherwise, and
    # "Unreadable" when the history cannot be read.
    param([Parameter(Mandatory = $true)][object]$Model, [AllowNull()][string]$Since)

    try {
        $history = Invoke-PowerBiRequest -Method GET -Uri "$script:PowerBiApi/groups/$($Model.workspaceId)/datasets/$($Model.id)/refreshes?`$top=1"
    } catch {
        if (Test-RefreshAuthorizationError $_) { throw }
        return "Unreadable"
    }
    $latest = @($history.value) | Select-Object -First 1
    if ($null -eq $latest) { return "Idle" }
    if ([string]$latest.status -eq "Unknown") { return "Busy" }
    if (-not [string]::IsNullOrWhiteSpace($Since) -and -not [string]::IsNullOrWhiteSpace([string]$latest.endTime)) {
        $ended = ConvertTo-RefreshUtcDate $latest.endTime
        if ($null -ne $ended -and $ended -ge (ConvertTo-RefreshUtcDate $Since).AddSeconds(-5)) { return "FinishedSince" }
    }
    return "Idle"
}

# --- the chain --------------------------------------------------------------------------------

function Start-RefreshDataflows {
    param([object[]]$Items)

    foreach ($item in $Items) {
        try {
            # Recorded before the request: the poll only accepts a transaction that
            # started at or after this moment, never a previous run's result.
            $item.triggeredAt = (Get-Date).ToUniversalTime().ToString("o")
            Invoke-PowerBiRequest -Method POST -Uri "$script:PowerBiApi/groups/$($item.workspaceId)/dataflows/$($item.id)/refreshes" -Body '{"notifyOption":"NoNotification"}' | Out-Null
            $item.status = "Running"
            Write-RefreshLog "Dataflow '$($item.name)' in '$($item.workspaceName)': running."
        } catch {
            $item.status = "Failed"
            $item.error = Get-RefreshShortError $_
            Write-RefreshLog "Dataflow '$($item.name)' in '$($item.workspaceName)': FAILED - $($item.error)"
        }
    }
}

function Register-RefreshUnreadable {
    # An unreadable status is not a refresh result. Count it, and only past the
    # budget report Unknown, never Failed, because no failure was observed.
    param([object]$Item, [string]$Kind, [string]$Reason)

    $Item.unreadableCount = [int]$Item.unreadableCount + 1
    if ($Item.unreadableCount -eq 1) {
        Write-RefreshLog "$Kind '$($Item.name)' in '$($Item.workspaceName)': status could not be read ($Reason); retrying."
    } elseif ($Item.unreadableCount % 5 -eq 0) {
        Write-RefreshLog "$Kind '$($Item.name)' in '$($Item.workspaceName)': status still unreadable after $($Item.unreadableCount) attempt(s)."
    }
    if ($Item.unreadableCount -ge $script:RefreshUnreadableLimit) {
        $Item.status = "Unknown"
        $Item.error = "Status unreadable after $($Item.unreadableCount) consecutive attempts; last error: $Reason The refresh may still have completed - check its refresh history in the Power BI service."
        Write-RefreshLog "$Kind '$($Item.name)' in '$($Item.workspaceName)': UNKNOWN - status unreadable after $($Item.unreadableCount) attempt(s); not treated as a refresh failure."
    }
}

function Clear-RefreshUnreadable {
    param([object]$Item, [string]$Kind)

    if ([int]$Item.unreadableCount -gt 0) {
        Write-RefreshLog "$Kind '$($Item.name)' in '$($Item.workspaceName)': status readable again after $($Item.unreadableCount) failed attempt(s)."
        $Item.unreadableCount = 0
    }
}

function Wait-RefreshDataflows {
    param([object[]]$Items, [object[]]$Models, [System.Diagnostics.Stopwatch]$Stopwatch)

    while (@($Items | Where-Object { -not (Test-TerminalDataflowStatus $_.status) }).Count -gt 0) {
        if ($Stopwatch.Elapsed.TotalHours -gt $script:RefreshBudgetHours) {
            foreach ($item in @($Items | Where-Object { -not (Test-TerminalDataflowStatus $_.status) })) {
                $item.status = "Failed"
                $item.error = "Timed out after $($script:RefreshBudgetHours) hours."
                Write-RefreshLog "Dataflow '$($item.name)' in '$($item.workspaceName)': FAILED - $($item.error)"
            }
            break
        }
        Wait-RefreshPollInterval

        foreach ($item in @($Items | Where-Object { -not (Test-TerminalDataflowStatus $_.status) })) {
            try {
                $transactions = Invoke-PowerBiRequest -Method GET -Uri "$script:PowerBiApi/groups/$($item.workspaceId)/dataflows/$($item.id)/transactions"
                Clear-RefreshUnreadable $item "Dataflow"
                $current = Select-RefreshCurrentEntry -Entries @($transactions.value) -TriggeredAt ([string]$item.triggeredAt)
                if ($null -eq $current) { continue }
                $status = [string]$current.status
                $outcome = ConvertTo-DataflowOutcome $status
                if ($outcome -eq "Succeeded") {
                    $item.status = "Succeeded"
                    $item.completedAt = ConvertTo-RefreshUtcStamp $current.endTime
                    Write-RefreshLog "Dataflow '$($item.name)' in '$($item.workspaceName)': succeeded."
                } elseif ($outcome -eq "Failed") {
                    $item.status = "Failed"
                    $item.completedAt = ConvertTo-RefreshUtcStamp $current.endTime
                    $item.error = if ($current.error) { Get-RefreshShortError $current.error } else { "Power BI reported status '$status'." }
                    Write-RefreshLog "Dataflow '$($item.name)' in '$($item.workspaceName)': FAILED - $($item.error)"
                }
            } catch {
                # As in the skill, a rejected sign-in during polling is counted as
                # unreadable too: the refresh itself may well finish.
                Register-RefreshUnreadable $item "Dataflow" (Get-RefreshShortError $_)
            }
        }
        Publish-RefreshStatus -DataflowStatus (Get-RefreshDataflowPhaseText $Items) -DatasetStatus "Pending" -Dataflows $Items -Models $Models
    }
}

function Start-RefreshModels {
    # Starts each model's refresh. A model that is already refreshing in the service
    # (started by someone or something else after the dataflows finished) is waited
    # for, and this run's refresh starts when that one ends, so the model is always
    # refreshed after all of its dataflows. A request refused while another refresh
    # runs is retried the same way, at most $script:RefreshModelRefusalLimit times.
    param([object[]]$Items, [object[]]$Dataflows, [System.Diagnostics.Stopwatch]$Stopwatch)

    if ($null -eq $Stopwatch) { $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew() }
    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Items) { $pending.Add($item) }
    $refusals = @{}
    $waitingLogged = @{}

    while ($pending.Count -gt 0) {
        foreach ($item in $pending.ToArray()) {
            $key = "$($item.workspaceId)/$($item.id)"
            if ((Get-RefreshModelActivity -Model $item) -eq "Busy") {
                if (-not $waitingLogged.ContainsKey($key)) {
                    $waitingLogged[$key] = $true
                    Write-RefreshLog "Semantic model '$($item.name)' in '$($item.workspaceName)': another refresh, not started by this run, is in progress; waiting for it to finish before starting this run's refresh."
                }
                continue
            }
            if ($waitingLogged.ContainsKey($key)) {
                $waitingLogged.Remove($key)
                Write-RefreshLog "Semantic model '$($item.name)' in '$($item.workspaceName)': the other refresh has finished; starting this run's refresh."
            }
            $attemptAt = (Get-Date).ToUniversalTime().ToString("o")
            try {
                $item.triggeredAt = $attemptAt
                $response = Invoke-PowerBiWebRequest -Method POST -Uri "$script:PowerBiApi/groups/$($item.workspaceId)/datasets/$($item.id)/refreshes" -Body '{"type":"Full","commitMode":"transactional"}'
                $location = [string]$response.Headers["Location"]
                $item.status = "Running"
                if ([string]::IsNullOrWhiteSpace($location)) {
                    $item.requestId = ""
                    Write-RefreshLog "Semantic model '$($item.name)' in '$($item.workspaceName)': running (accepted without a status location; polling refresh history)."
                } else {
                    $item.requestId = ($location -split '/')[-1]
                    Write-RefreshLog "Semantic model '$($item.name)' in '$($item.workspaceName)': running."
                }
                [void]$pending.Remove($item)
            } catch {
                if (Test-RefreshAuthorizationError $_) { throw }
                $reason = Get-RefreshRequestError $_
                $activity = Get-RefreshModelActivity -Model $item -Since $attemptAt
                $refusals[$key] = [int]$refusals[$key] + 1
                if ($activity -in @("Busy", "FinishedSince") -and $refusals[$key] -lt $script:RefreshModelRefusalLimit) {
                    Write-RefreshLog "Semantic model '$($item.name)' in '$($item.workspaceName)': the refresh request was refused while another refresh was running ($reason); waiting and trying again."
                    if ($activity -eq "Busy") { $waitingLogged[$key] = $true }
                    continue
                }
                $item.status = "Failed"
                $item.error = if ($activity -in @("Busy", "FinishedSince")) { "Refused $($refusals[$key]) times while other refreshes of this model were running; last reason: $reason" } else { $reason }
                Write-RefreshLog "Semantic model '$($item.name)' in '$($item.workspaceName)': FAILED - $($item.error)"
                [void]$pending.Remove($item)
            }
        }
        if ($pending.Count -eq 0) { break }
        if ($Stopwatch.Elapsed.TotalHours -gt $script:RefreshBudgetHours) {
            foreach ($item in $pending.ToArray()) {
                $item.status = "Failed"
                $item.error = "Timed out after $($script:RefreshBudgetHours) hours waiting for another refresh of this model to finish; this run's refresh was not started."
                Write-RefreshLog "Semantic model '$($item.name)' in '$($item.workspaceName)': FAILED - $($item.error)"
            }
            break
        }
        Publish-RefreshStatus -DataflowStatus (Get-RefreshFinalDataflowStatus $Dataflows) -DatasetStatus "Waiting for another refresh to finish ($($pending.Count) model(s))" -Dataflows $Dataflows -Models $Items
        Wait-RefreshPollInterval
    }
}

function Update-RefreshModelStatus {
    param([object]$Item)

    if ([string]::IsNullOrWhiteSpace([string]$Item.requestId)) {
        $history = Invoke-PowerBiRequest -Method GET -Uri "$script:PowerBiApi/groups/$($Item.workspaceId)/datasets/$($Item.id)/refreshes?`$top=10"
        $state = Select-RefreshCurrentEntry -Entries @($history.value) -TriggeredAt ([string]$Item.triggeredAt)
        if ($null -eq $state) { return }
    } else {
        $state = Invoke-PowerBiRequest -Method GET -Uri "$script:PowerBiApi/groups/$($Item.workspaceId)/datasets/$($Item.id)/refreshes/$($Item.requestId)"
    }

    # A refresh still running has no end time; the column then shows a dash.
    if (-not [string]::IsNullOrWhiteSpace([string]$state.endTime)) { $Item.completedAt = ConvertTo-RefreshUtcStamp $state.endTime }
    $outcome = ConvertTo-ModelOutcome $state
    if ($outcome.Status -eq "Succeeded") {
        $Item.status = "Succeeded"
        Write-RefreshLog "Semantic model '$($Item.name)' in '$($Item.workspaceName)': succeeded."
    } elseif ($outcome.Status -eq "Failed") {
        $Item.status = "Failed"
        $Item.error = $outcome.Error
        Write-RefreshLog "Semantic model '$($Item.name)' in '$($Item.workspaceName)': FAILED - $($Item.error)"
    }
}

function Wait-RefreshModels {
    param([object[]]$Items, [object[]]$Dataflows, [System.Diagnostics.Stopwatch]$Stopwatch)

    while (@($Items | Where-Object { -not (Test-TerminalModelStatus $_.status) }).Count -gt 0) {
        if ($Stopwatch.Elapsed.TotalHours -gt $script:RefreshBudgetHours) {
            foreach ($item in @($Items | Where-Object { -not (Test-TerminalModelStatus $_.status) })) {
                $item.status = "Failed"
                $item.error = "Timed out after $($script:RefreshBudgetHours) hours."
                Write-RefreshLog "Semantic model '$($item.name)' in '$($item.workspaceName)': FAILED - $($item.error)"
            }
            break
        }
        Wait-RefreshPollInterval

        foreach ($item in @($Items | Where-Object { -not (Test-TerminalModelStatus $_.status) })) {
            try {
                Update-RefreshModelStatus -Item $item
                Clear-RefreshUnreadable $item "Semantic model"
            } catch {
                Register-RefreshUnreadable $item "Semantic model" (Get-RefreshShortError $_)
            }
        }
        $succeeded = @($Items | Where-Object { $_.status -eq "Succeeded" }).Count
        $failed = @($Items | Where-Object { $_.status -in @("Failed", "Unknown") }).Count
        Publish-RefreshStatus -DataflowStatus (Get-RefreshFinalDataflowStatus $Dataflows) -DatasetStatus "Running ($succeeded/$(@($Items).Count); $failed failed)" -Dataflows $Dataflows -Models $Items
    }
}

# --- validation stage -----------------------------------------------------------------------

function New-RefreshValidationEntries {
    # One entry per semantic model: the checks to run (the report config that matches
    # the model's workspace and name, else the universal checks) and where to run them.
    param([Parameter(Mandatory = $true)][object]$Plan)

    $entries = @()
    $models = @($Plan.Models)
    foreach ($model in $models) {
        $reportName = if ($Plan.Kind -eq "report") { [string]$Plan.Report } else { "" }
        $config = Find-ValidationConfigForModel -WorkspaceName $model.workspaceName -ModelName $model.name -ReportName $reportName -ToolRoot $script:RefreshValidationRoot
        if ($null -eq $config) {
            $config = New-ValidationUniversalConfig -WorkspaceName $model.workspaceName -ReportName $reportName -ModelName $model.name -ToolRoot $script:RefreshValidationRoot
        }
        $entries += [pscustomobject]@{
            Model = $model
            Config = $config
            Target = [pscustomobject]@{ modelWorkspaceId = $model.workspaceId; datasetId = $model.id; workspaceName = $model.workspaceName; reportName = $reportName }
            Before = $null
            After = $null
            Compare = $null
            Error = ""
        }
    }
    return $entries
}

function Invoke-RefreshValidationSnapshot {
    # Takes the before or after snapshot of one model. A snapshot that cannot be taken
    # never stops the refresh: the reason is kept and the email says validation did not run.
    param(
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][ValidateSet("before", "after")][string]$Phase,
        [AllowNull()][string]$RunFolder,
        [int]$Index = 1
    )

    $label = "semantic model '$($Entry.Model.name)'"
    try {
        Confirm-RefreshAuthorization
        $snapshot = Get-ValidationSnapshot -Config $Entry.Config -Target $Entry.Target -Headers $script:RefreshHeaders
    } catch {
        $Entry.Error = "the $Phase-refresh snapshot could not be taken: $(Get-RefreshShortError $_)"
        Write-RefreshLog "WARNING: Validation of $label`: $($Entry.Error)"
        return
    }
    if ($Phase -eq "before") { $Entry.Before = $snapshot } else { $Entry.After = $snapshot }
    $errors = @($snapshot.checks | Where-Object { $_.status -eq "Error" })
    $kind = if ($null -ne $Entry.Config.PSObject.Properties["universal"] -and $Entry.Config.universal) { "universal checks" } else { "report config checks" }
    Write-RefreshLog "Validation of $label`: $Phase-refresh snapshot taken ($(@($snapshot.checks).Count) $kind, $($errors.Count) could not run)."
    if ($RunFolder) {
        try { Write-RefreshJsonFile -Path (Join-Path $RunFolder "validation-$Index-$Phase.json") -Value $snapshot } catch { }
    }
}

function Complete-RefreshValidation {
    # After the refresh: the after snapshots and the comparisons.
    param([object[]]$Entries, [AllowNull()][string]$RunFolder)

    $index = 0
    foreach ($entry in @($Entries)) {
        $index++
        if ($null -eq $entry.Before) { continue }
        Invoke-RefreshValidationSnapshot -Entry $entry -Phase "after" -RunFolder $RunFolder -Index $index
        if ($null -eq $entry.After) { continue }
        try {
            $entry.Compare = Compare-ValidationSnapshots -Before $entry.Before -After $entry.After -Config $entry.Config
            if ($RunFolder) { try { Write-RefreshJsonFile -Path (Join-Path $RunFolder "validation-$index-compare.json") -Value $entry.Compare } catch { } }
            $c = $entry.Compare.counts
            Write-RefreshLog "Validation of semantic model '$($entry.Model.name)': $($entry.Compare.overall) ($($c.pass) passed, $($c.warn) warned, $($c.fail) failed of $($c.total))."
        } catch {
            $entry.Error = "the comparison failed: $(Get-RefreshShortError $_)"
            Write-RefreshLog "WARNING: Validation of semantic model '$($entry.Model.name)': $($entry.Error)"
        }
    }
}

function Get-RefreshValidationSummary {
    # The validation result as recorded in summary.json; null when validation was off.
    param([AllowNull()][object[]]$Entries, [switch]$Disabled)

    if ($Disabled) { return $null }
    $models = @(foreach ($entry in @($Entries)) {
        $universal = $null -ne $entry.Config.PSObject.Properties["universal"] -and $entry.Config.universal
        [pscustomobject][ordered]@{
            name = $entry.Model.name
            workspaceName = $entry.Model.workspaceName
            checks = if ($universal) { "universal" } else { [System.IO.Path]::GetFileName([string]$entry.Config.configPath) }
            overall = if ($null -ne $entry.Compare) { [string]$entry.Compare.overall } else { "NotRun" }
            counts = if ($null -ne $entry.Compare) { $entry.Compare.counts } else { $null }
            error = [string]$entry.Error
        }
    })
    $verdicts = @($models | ForEach-Object { if ($_.overall -eq "NotRun") { "FAIL" } else { $_.overall } })
    return [pscustomobject][ordered]@{
        Overall = if ($models.Count -eq 0) { "NotRun" } else { Get-ValidationWorstVerdict $verdicts }
        Models = $models
    }
}

function Get-RefreshEmailTitle {
    # The name in the email subject: the report, or the semantic models of a profile.
    param([Parameter(Mandatory = $true)][object]$Plan)

    if ($Plan.Kind -eq "report" -and -not [string]::IsNullOrWhiteSpace([string]$Plan.Report)) { return [string]$Plan.Report }
    $names = @($Plan.Models | ForEach-Object { [string]$_.name } | Where-Object { $_ })
    if ($names.Count -eq 0) { return [string]$Plan.Workspace }
    if ($names.Count -le 2) { return ($names -join ", ") }
    return "$($names[0]) and $($names.Count - 1) more"
}

function Complete-RefreshNotification {
    # The one email of every run: the refresh table and a validation section per
    # semantic model (validation\validation.ps1). The rendered email is always kept
    # in the run folder, also when there are no recipients or the send fails.
    param(
        [object[]]$Dataflows,
        [object[]]$Models,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [string[]]$Recipients,
        [switch]$Preview,
        [AllowNull()][object[]]$Validation,
        [string]$Title = "",
        [AllowNull()][string]$RunFolder
    )

    $refreshView = [pscustomobject]@{
        Dataflows = @($Dataflows | Select-Object workspaceName, name, status, error, completedAt)
        SemanticModels = @($Models | Select-Object workspaceName, name, status, error, completedAt)
    }
    $emptyCompare = [pscustomobject][ordered]@{ overall = "FAIL"; counts = [pscustomobject][ordered]@{ total = 0; pass = 0; warn = 0; fail = 0; info = 0 }; checks = @() }
    $sections = @(foreach ($entry in @($Validation)) {
        if ($null -ne $entry.Compare) {
            [pscustomobject]@{ Compare = $entry.Compare; Config = $entry.Config; BaselineNote = "this run's pre-refresh snapshot" }
        } else {
            $reason = if ($entry.Error) { $entry.Error } else { "no snapshot" }
            [pscustomobject]@{ Compare = $emptyCompare; Config = $entry.Config; BaselineNote = "not available ($reason)" }
        }
    })
    $content = New-ValidationEmailContent -Sections $sections -RefreshSummary $refreshView -RunFolder ([string]$RunFolder) -StartedAt $StartTime -EndedAt $EndTime -Title $Title
    if ($RunFolder) {
        $fileName = if ($Preview) { "email-preview.html" } else { "email.html" }
        try { [System.IO.File]::WriteAllText((Join-Path $RunFolder $fileName), $content.HtmlBody, (New-Object System.Text.UTF8Encoding($false))) } catch { }
    }

    if (@($Recipients).Count -eq 0) { return [pscustomobject]@{ Status = "Skipped"; Warning = "" } }
    if ($Preview) {
        Write-RefreshLog "=== EMAIL PREVIEW (nothing sent) ==="
        Write-RefreshLog "Recipients: $($Recipients -join ', ')"
        Write-RefreshLog "Subject: $($content.Subject)"
        foreach ($item in @($refreshView.Dataflows)) { Write-RefreshLog "  Dataflow | $($item.workspaceName) | $($item.name) | $($item.status)$(if ($item.error) { ' | ' + $item.error })" }
        foreach ($item in @($refreshView.SemanticModels)) { Write-RefreshLog "  Semantic model | $($item.workspaceName) | $($item.name) | $($item.status)$(if ($item.error) { ' | ' + $item.error })" }
        if ($RunFolder) { Write-RefreshLog "  The rendered email is email-preview.html in the run folder." }
        return [pscustomobject]@{ Status = "Preview"; Warning = "" }
    }

    $webhookUrl = Get-RefreshWebhookUrl
    if ([string]::IsNullOrWhiteSpace($webhookUrl)) {
        $warning = "Email was not sent because REFRESH_EMAIL_WEBHOOK_URL is not configured."
        Write-RefreshLog "WARNING: $warning"
        return [pscustomobject]@{ Status = "Failed"; Warning = $warning }
    }
    try {
        Send-RefreshEmail -WebhookUrl $webhookUrl -Recipients $Recipients -Subject $content.Subject -HtmlBody $content.HtmlBody
        Write-RefreshLog "Notification email submitted for $(@($Recipients).Count) recipient(s)."
        return [pscustomobject]@{ Status = "Sent"; Warning = "" }
    } catch {
        $warning = "Refresh finished, but the notification email failed: $(Get-RefreshShortError $_)"
        Write-RefreshLog "WARNING: $warning"
        return [pscustomobject]@{ Status = "Failed"; Warning = $warning }
    }
}

function Write-RefreshPlan {
    param([object]$Plan, [string[]]$Recipients, [switch]$Preview)

    $webhookConfigured = -not [string]::IsNullOrWhiteSpace((Get-RefreshWebhookUrl))
    $emailMode = if (@($Recipients).Count -eq 0) { "Off" } elseif ($Preview) { "Preview only" } elseif (-not $webhookConfigured) { "Requested, but webhook not configured" } else { "Live" }
    $upstream = @($Plan.Dataflows | ForEach-Object { "$($_.workspaceName) / $($_.name)" })
    if ($Plan.Kind -eq "report") {
        # The same fields, in the same order, as the skill's plan before it moved
        # onto this runner ($RefreshReportPlanFields in _refresh-contract.ps1).
        $view = [pscustomobject][ordered]@{
            Workspace = $Plan.Workspace
            Report = $Plan.Report
            SemanticModel = [string]@($Plan.Models)[0].name
            UpstreamDataflows = $upstream
            ExcludedDataflows = @($Plan.Excluded)
            Recipients = @($Recipients)
            Email = $emailMode
            Authentication = $script:RefreshAuthMode
        }
    } else {
        $view = [pscustomobject][ordered]@{
            Workspace = $Plan.Workspace
            SemanticModels = @($Plan.Models | ForEach-Object { "$($_.workspaceName) / $($_.name)" })
            UpstreamDataflows = $upstream
            ExcludedDataflows = @($Plan.Excluded)
            Recipients = @($Recipients)
            Email = $emailMode
            Authentication = $script:RefreshAuthMode
        }
    }
    Write-Host "Read-only refresh plan; no remote refresh was started." -ForegroundColor Cyan
    $view | Format-List | Out-Host
    Write-Host "Obtain explicit confirmation, then repeat this command with -Confirmed." -ForegroundColor Yellow
    return $view
}

function Invoke-RefreshRun {
    # One refresh run from sign-in to summary. Returns $null for a plan-only call
    # (no -Confirmed), otherwise an object with Failed, RunFolder and Summary.
    # Throws when the run cannot start (sign-in, discovery, lock, model busy);
    # the status file then records the failure for the Control Panel.
    param(
        [string]$WorkspaceName,
        [string]$ReportName,
        [AllowNull()][object]$Plan,
        [AllowNull()][string[]]$ExcludeDataflow,
        [AllowNull()][string[]]$Recipients,
        [switch]$PreviewEmail,
        [switch]$Confirmed,
        [AllowNull()][string]$StatusFile,
        [AllowNull()][string]$RunsRoot,
        [Parameter(Mandatory = $true)][string]$EmailModulePath,
        [AllowNull()][string]$InitialToken,
        [AllowNull()][string]$InitialMode,
        # Only for a caller that runs its own validation around this run (the validated
        # refresh with its history and baselines); everyone else gets it here.
        [switch]$NoValidation
    )

    $script:RefreshStatusFile = if ([string]::IsNullOrWhiteSpace($StatusFile)) { $null } else { $StatusFile }
    $script:RefreshLogFile = $null
    $script:RefreshWorkspaceNames = @{}
    $startedAt = Get-Date
    $lockPaths = @()
    $runFolder = $null

    try {
        $byName = -not [string]::IsNullOrWhiteSpace($WorkspaceName) -or -not [string]::IsNullOrWhiteSpace($ReportName)
        if ($byName -and $null -ne $Plan) { throw "Pass either workspace and report names or a refresh plan, not both." }
        if ($byName -and ([string]::IsNullOrWhiteSpace($WorkspaceName) -or [string]::IsNullOrWhiteSpace($ReportName))) { throw "Both a workspace name and a report name are required." }
        if (-not $byName -and $null -eq $Plan) { throw "Pass workspace and report names or a refresh plan." }
        if (-not (Test-Path -LiteralPath $EmailModulePath)) { throw "Required notification module not found: refresh-email.ps1." }
        . $EmailModulePath

        $notificationRecipients = @(ConvertTo-RefreshRecipientList @($Recipients))
        if ($Confirmed) { Initialize-RefreshStatusFile -StartedAt $startedAt -EmailRequested ($notificationRecipients.Count -gt 0) }
        Initialize-RefreshAuthorization -InitialToken $InitialToken -InitialMode $InitialMode
        $resolved = if ($byName) { Resolve-RefreshPlanByName -WorkspaceName $WorkspaceName -ReportName $ReportName } else { Resolve-RefreshPlanByIds -Plan $Plan }
        $resolved = Set-RefreshPlanExclusions -Plan $resolved -ExcludeDataflow $ExcludeDataflow
        if (@($resolved.Models).Count -eq 0 -and @($resolved.Dataflows).Count -eq 0) { throw "Nothing is left to refresh." }

        if (-not $Confirmed) {
            Write-RefreshPlan -Plan $resolved -Recipients $notificationRecipients -Preview:$PreviewEmail | Out-Null
            return $null
        }

        $root = Resolve-RefreshRunsRoot $RunsRoot
        $runFolder = New-RefreshRunFolder -RunsRoot $root
        $script:RefreshLogFile = Join-Path $runFolder "refresh-log.txt"

        # One run per semantic model at a time, across the Control Panel, the skill
        # and the validated refresh; and never while the service is refreshing it.
        foreach ($model in $resolved.Models) {
            $lockPath = Get-RefreshLockPath -RunsRoot $root -WorkspaceId $model.workspaceId -DatasetId $model.id
            Enter-RefreshRunLock -Path $lockPath -RunFolder $runFolder -Label "semantic model '$($model.name)'"
            $lockPaths += $lockPath
        }
        foreach ($model in $resolved.Models) {
            if (Test-RefreshModelBusy -Model $model) {
                throw "Semantic model '$($model.name)' in '$($model.workspaceName)' is already refreshing in the Power BI service. Nothing was started."
            }
        }
    } catch {
        $message = Get-RefreshShortError $_
        if ($script:RefreshLogFile) { Write-RefreshLog "ERROR: $message" }
        if ($Confirmed -and $script:RefreshStatusFile) {
            $endedAt = Get-Date
            Update-RefreshStatusFile {
                param($state)
                $state.running = $false
                $state.result = "Failed"
                $state.endTime = $endedAt.ToString("o")
                $state.durationSeconds = [math]::Round(($endedAt - $startedAt).TotalSeconds, 1)
                $state.dataflowStatus = "Failed"
                $state.datasetStatus = "Skipped"
                $state.error = $message
            }
        }
        foreach ($path in $lockPaths) { Exit-RefreshRunLock -Path $path }
        throw
    }

    $dataflows = @($resolved.Dataflows)
    $models = @($resolved.Models)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $refreshFailed = $false
    $refreshErrors = New-Object System.Collections.Generic.List[string]
    $emailResult = [pscustomobject]@{ Status = if ($notificationRecipients.Count -gt 0) { "Pending" } else { "Skipped" }; Warning = "" }
    $summary = $null
    $validation = @()

    try {
        if ($resolved.Kind -eq "report") {
            Write-RefreshLog "Starting report '$($resolved.Report)' in workspace '$($resolved.Workspace)'."
        } else {
            Write-RefreshLog "Starting refresh plan in workspace '$($resolved.Workspace)': $($dataflows.Count) dataflow(s), $($models.Count) semantic model(s)."
        }
        Write-RefreshLog "Authentication: $($script:RefreshAuthMode)."
        if (@($resolved.Excluded).Count -gt 0) { Write-RefreshLog "Excluded by request and NOT refreshed: $($resolved.Excluded -join '; ')." }
        Publish-RefreshStatus -DataflowStatus "Pending" -DatasetStatus "Pending" -Dataflows $dataflows -Models $models

        # Before anything is triggered: what each semantic model holds now. Read-only
        # DAX queries; a snapshot that fails is reported, never a reason to stop.
        if (-not $NoValidation) {
            try {
                $validation = @(New-RefreshValidationEntries -Plan $resolved)
            } catch {
                Write-RefreshLog "WARNING: Validation could not be prepared: $(Get-RefreshShortError $_)"
                $validation = @()
            }
            $index = 0
            foreach ($entry in $validation) {
                $index++
                Invoke-RefreshValidationSnapshot -Entry $entry -Phase "before" -RunFolder $runFolder -Index $index
            }
        }

        if ($dataflows.Count -eq 0) {
            Write-RefreshLog "No upstream dataflows to refresh; starting the semantic model refresh."
        } else {
            Write-RefreshLog "Starting $($dataflows.Count) upstream dataflow refresh(es) in parallel."
            Start-RefreshDataflows -Items $dataflows
            Publish-RefreshStatus -DataflowStatus (Get-RefreshDataflowPhaseText $dataflows) -DatasetStatus "Pending" -Dataflows $dataflows -Models $models
            Wait-RefreshDataflows -Items $dataflows -Models $models -Stopwatch $stopwatch
        }

        $failedDataflows = @($dataflows | Where-Object { $_.status -eq "Failed" })
        $unverifiedDataflows = @($dataflows | Where-Object { $_.status -eq "Unknown" })
        if ($failedDataflows.Count -gt 0 -or $unverifiedDataflows.Count -gt 0) {
            $refreshFailed = $true
            foreach ($item in $failedDataflows) { $refreshErrors.Add("Dataflow '$($item.name)': $($item.error)") }
            foreach ($item in $unverifiedDataflows) { $refreshErrors.Add("Dataflow '$($item.name)' (unverified): $($item.error)") }
            # An unverified input is no safer than a failed one, but the stated
            # reason must not claim a failure nobody observed.
            $skipReason = if ($failedDataflows.Count -gt 0) { "Not started because one or more upstream dataflows failed." } else { "Not started because the result of one or more upstream dataflows could not be verified." }
            foreach ($item in $models) { $item.status = "Skipped"; $item.error = $skipReason }
            Write-RefreshLog "Semantic model refresh skipped because not all upstream dataflows were confirmed successful."
        } else {
            if ($dataflows.Count -gt 0) { Write-RefreshLog "All upstream dataflows completed successfully; starting semantic model refresh." }
            Publish-RefreshStatus -DataflowStatus (Get-RefreshFinalDataflowStatus $dataflows) -DatasetStatus "Running" -Dataflows $dataflows -Models $models
            Start-RefreshModels -Items $models -Dataflows $dataflows -Stopwatch $stopwatch
            Wait-RefreshModels -Items $models -Dataflows $dataflows -Stopwatch $stopwatch
            foreach ($item in @($models | Where-Object { $_.status -in @("Failed", "Unknown") })) {
                $refreshFailed = $true
                $refreshErrors.Add("Semantic model '$($item.name)': $($item.error)")
            }
        }
    } catch {
        $refreshFailed = $true
        $unexpected = Get-RefreshShortError $_
        $refreshErrors.Add($unexpected)
        Write-RefreshLog "ERROR: $unexpected"
        foreach ($item in @($dataflows | Where-Object { $_.status -in @("Pending", "Running") })) { $item.status = "Failed"; $item.error = $unexpected }
        $anyDataflowBad = @($dataflows | Where-Object { $_.status -in @("Failed", "Unknown") }).Count -gt 0
        foreach ($item in @($models | Where-Object { $_.status -in @("Pending", "Running") })) {
            $item.status = if ($anyDataflowBad) { "Skipped" } else { "Failed" }
            $item.error = $unexpected
        }
    } finally {
        # After the refresh, also a failed one: the after snapshots and the comparison.
        if (@($validation).Count -gt 0) {
            try { Complete-RefreshValidation -Entries $validation -RunFolder $runFolder } catch { Write-RefreshLog "WARNING: Validation could not be completed: $(Get-RefreshShortError $_)" }
        }
        $endedAt = Get-Date
        try {
            $emailResult = Complete-RefreshNotification -Dataflows $dataflows -Models $models -StartTime $startedAt -EndTime $endedAt -Recipients $notificationRecipients -Preview:$PreviewEmail `
                -Validation $validation -Title (Get-RefreshEmailTitle -Plan $resolved) -RunFolder $runFolder
        } catch {
            $emailResult = [pscustomobject]@{ Status = "Failed"; Warning = "Refresh finished, but the notification could not be prepared: $(Get-RefreshShortError $_)" }
            Write-RefreshLog "WARNING: $($emailResult.Warning)"
        }
        if ($refreshFailed) {
            Write-RefreshLog "COMPLETED WITH ERRORS: $($refreshErrors.Count) refresh error(s)."
        } else {
            Write-RefreshLog "SUCCESS: All refreshes completed ($($dataflows.Count) dataflow(s) + $($models.Count) semantic model(s))."
        }

        $summary = [pscustomobject][ordered]@{
            Workspace = [string]$resolved.Workspace
            Report = [string]$resolved.Report
            SemanticModel = (@($models | ForEach-Object { $_.name }) -join "; ")
            Result = if ($refreshFailed) { "Failed" } else { "Succeeded" }
            StartedAt = $startedAt.ToString("o")
            EndedAt = $endedAt.ToString("o")
            DurationSeconds = [math]::Round(($endedAt - $startedAt).TotalSeconds, 1)
            Dataflows = @($dataflows | Select-Object workspaceName, name, status, error, completedAt)
            ExcludedDataflows = @($resolved.Excluded)
            SemanticModels = @($models | Select-Object workspaceName, name, status, error, completedAt)
            Validation = Get-RefreshValidationSummary -Entries $validation -Disabled:$NoValidation
            EmailStatus = $emailResult.Status
            EmailWarning = $emailResult.Warning
            Recipients = @($notificationRecipients)
            Authentication = $script:RefreshAuthMode
            Artifacts = $runFolder
        }
        try { Write-RefreshJsonFile -Path (Join-Path $runFolder "summary.json") -Value $summary } catch { Write-RefreshLog "WARNING: summary.json could not be written: $(Get-RefreshShortError $_)" }

        $errorText = if ($refreshFailed) { $refreshErrors -join " | " } else { "" }
        $finalDataflowStatus = Get-RefreshFinalDataflowStatus $dataflows
        $finalModelStatus = Get-RefreshFinalModelStatus $models
        $resultText = $summary.Result
        Update-RefreshStatusFile {
            param($state)
            $state.running = $false
            $state.result = $resultText
            $state.endTime = $endedAt.ToString("o")
            $state.durationSeconds = $summary.DurationSeconds
            $state.dataflowDetails = @($dataflows)
            $state.semanticModelDetails = @($models)
            $state.dataflowStatus = $finalDataflowStatus
            $state.datasetStatus = $finalModelStatus
            $state.emailStatus = $emailResult.Status
            $state.emailWarning = $emailResult.Warning
            $state.error = $errorText
        }
        foreach ($path in $lockPaths) { Exit-RefreshRunLock -Path $path }
    }

    return [pscustomobject]@{ Failed = $refreshFailed; RunFolder = $runFolder; Summary = $summary }
}
