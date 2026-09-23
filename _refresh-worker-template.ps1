$ErrorActionPreference = "Stop"
$statusFile = "{{StatusFile}}"
$logsDir = "{{LogsDir}}"
$emailModule = "{{EmailModule}}"
$token = "{{Token}}"
$payloadJson = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("{{RefreshPayload}}"))
$payload = $payloadJson | ConvertFrom-Json
$ws = [string]$payload.WorkspaceId
$dfs = @($payload.DataflowIds)
$semanticModels = @($payload.SemanticModels)
$recipients = @($payload.NotificationRecipients)
$emailDryRun = [bool]$payload.EmailDryRun

. $emailModule

function Get-ShortError {
    param([AllowNull()][object]$Value)

    $message = if ($Value -is [System.Management.Automation.ErrorRecord]) { $Value.Exception.Message } else { [string]$Value }
    $message = ($message -replace '[\r\n]+', ' ').Trim()
    if ($message.Length -gt 240) { return $message.Substring(0, 237) + "..." }
    return $message
}

function Write-RefreshState {
    param([scriptblock]$Update)

    try {
        $state = Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json
        & $Update $state
        $state | ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath $statusFile
    } catch { }
}

function Log {
    param([string]$Message)

    Write-RefreshState { param($state) $state.logs += @{ time = (Get-Date -Format "HH:mm:ss"); text = $Message } }
    try {
        $logLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Message"
        [System.IO.File]::AppendAllText((Join-Path $logsDir "refresh-log.txt"), $logLine + [Environment]::NewLine)
    } catch { }
}

function Publish-Status {
    param(
        [string]$DataflowStatus,
        [string]$SemanticModelStatus,
        [AllowNull()][object]$Running,
        [AllowNull()][object[]]$DataflowDetails,
        [AllowNull()][object[]]$SemanticModelDetails
    )

    Write-RefreshState {
        param($state)
        if ($DataflowStatus) { $state.dataflowStatus = $DataflowStatus }
        if ($SemanticModelStatus) { $state.datasetStatus = $SemanticModelStatus }
        if ($null -ne $Running) { $state.running = [bool]$Running }
        if ($null -ne $DataflowDetails) { $state.dataflowDetails = @($DataflowDetails) }
        if ($null -ne $SemanticModelDetails) { $state.semanticModelDetails = @($SemanticModelDetails) }
    }
}

function Get-WorkspaceName {
    param([string]$WorkspaceId)

    if ($workspaceNames.ContainsKey($WorkspaceId)) { return $workspaceNames[$WorkspaceId] }
    try {
        $group = Invoke-RestMethod -Method GET -Uri "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId" -Headers $headers
        $name = if ($group.name) { [string]$group.name } else { $WorkspaceId }
    } catch {
        $name = $WorkspaceId
        Log "WARNING: Could not resolve workspace name for $WorkspaceId."
    }
    $workspaceNames[$WorkspaceId] = $name
    return $name
}

function Get-DataflowName {
    param([string]$WorkspaceId, [string]$DataflowId)

    try {
        $item = Invoke-RestMethod -Method GET -Uri "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/dataflows/$DataflowId" -Headers $headers
        if ($item.name) { return [string]$item.name }
    } catch { }
    return $DataflowId
}

function Get-SemanticModelName {
    param([string]$WorkspaceId, [string]$DatasetId)

    try {
        $item = Invoke-RestMethod -Method GET -Uri "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/datasets/$DatasetId" -Headers $headers
        if ($item.name) { return [string]$item.name }
    } catch { }
    return $DatasetId
}

function Test-TerminalDataflowStatus {
    param([string]$Status)
    return @("Succeeded", "Failed") -contains $Status
}

function Test-TerminalModelStatus {
    param([string]$Status)
    return @("Succeeded", "Failed", "Skipped") -contains $Status
}

function Complete-Notification {
    param(
        [object[]]$DataflowDetails,
        [object[]]$ModelDetails,
        [datetime]$StartTime,
        [datetime]$EndTime
    )

    if ($recipients.Count -eq 0) { return }

    $items = @()
    foreach ($detail in $DataflowDetails) {
        $items += [pscustomobject]@{
            Type = "Dataflow"
            Name = $detail.name
            WorkspaceName = $detail.workspaceName
            Status = $detail.status
            Error = $detail.error
        }
    }
    foreach ($detail in $ModelDetails) {
        $items += [pscustomobject]@{
            Type = "Semantic model"
            Name = $detail.name
            WorkspaceName = $detail.workspaceName
            Status = $detail.status
            Error = $detail.error
        }
    }

    $content = Get-RefreshEmailContent -Items $items -StartTime $StartTime -EndTime $EndTime
    if ($emailDryRun) {
        Log "=== EMAIL PREVIEW (dry run; nothing sent) ==="
        Log "Recipients: $($recipients -join ', ')"
        Log "Subject: $($content.Subject)"
        foreach ($item in $items) {
            $errorSuffix = if ($item.Error) { " | $($item.Error)" } else { "" }
            Log "  $($item.Type) | $($item.WorkspaceName) | $($item.Name) | $($item.Status)$errorSuffix"
        }
        Write-RefreshState { param($state) $state.emailStatus = "Preview" }
        return
    }

    $webhookUrl = [Environment]::GetEnvironmentVariable("REFRESH_EMAIL_WEBHOOK_URL")
    if ([string]::IsNullOrWhiteSpace($webhookUrl)) {
        $warning = "Email was not sent because REFRESH_EMAIL_WEBHOOK_URL is not configured."
        Log "WARNING: $warning"
        Write-RefreshState { param($state) $state.emailStatus = "Failed"; $state.emailWarning = $warning }
        return
    }

    try {
        Send-RefreshEmail -WebhookUrl $webhookUrl -Recipients $recipients -Subject $content.Subject -HtmlBody $content.HtmlBody
        Log "Notification email submitted for $($recipients.Count) recipient(s)."
        Write-RefreshState { param($state) $state.emailStatus = "Sent" }
    } catch {
        $warning = "Refresh finished, but the notification email failed: $(Get-ShortError $_)"
        Log "WARNING: $warning"
        Write-RefreshState { param($state) $state.emailStatus = "Failed"; $state.emailWarning = $warning }
    }
}

try {
    @{ phase = "worker-started"; time = (Get-Date -Format "o") } | ConvertTo-Json | Out-File (Join-Path $logsDir "worker-start.log") -Encoding utf8
} catch { }

$startedAt = Get-Date
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
$workspaceNames = @{}
$dataflowDetails = @()
$modelDetails = @()
$refreshErrors = New-Object System.Collections.Generic.List[string]
$refreshFailed = $false
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

[ordered]@{
    running = $true
    result = "Running"
    startTime = $startedAt.ToString("o")
    endTime = ""
    durationSeconds = 0
    logs = @()
    dataflowStatus = "Pending"
    datasetStatus = "Pending"
    dataflowDetails = @()
    semanticModelDetails = @()
    emailStatus = if ($recipients.Count -gt 0) { "Pending" } else { "Skipped" }
    emailWarning = ""
    error = ""
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statusFile

try {
    foreach ($df in $dfs) {
        $dataflowDetails += [pscustomobject][ordered]@{
            id = [string]$df
            workspaceId = $ws
            workspaceName = Get-WorkspaceName $ws
            name = Get-DataflowName $ws ([string]$df)
            status = "Pending"
            error = ""
        }
    }
    foreach ($model in $semanticModels) {
        $modelWorkspaceId = [string]$model.WorkspaceId
        $modelDatasetId = [string]$model.DatasetId
        $modelDetails += [pscustomobject][ordered]@{
            id = $modelDatasetId
            workspaceId = $modelWorkspaceId
            workspaceName = Get-WorkspaceName $modelWorkspaceId
            name = Get-SemanticModelName $modelWorkspaceId $modelDatasetId
            requestId = ""
            status = "Pending"
            error = ""
        }
    }

    Publish-Status "Pending" "Pending" $true $dataflowDetails $modelDetails

    Log "=== DATAFLOWS: triggering $($dataflowDetails.Count) dataflow(s) ==="
    foreach ($detail in $dataflowDetails) {
        try {
            Invoke-WebRequest -Method POST -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($detail.workspaceId)/dataflows/$($detail.id)/refreshes" -Headers $headers -Body '{"notifyOption":"NoNotification"}' -UseBasicParsing | Out-Null
            $detail.status = "Running"
            Log "  Dataflow '$($detail.name)' in '$($detail.workspaceName)': running."
        } catch {
            $detail.status = "Failed"
            $detail.error = Get-ShortError $_
            Log "  Dataflow '$($detail.name)' in '$($detail.workspaceName)': FAILED - $($detail.error)"
        }
    }
    Publish-Status "Running" "Pending" $true $dataflowDetails $modelDetails

    Log "=== DATAFLOWS: polling ==="
    while (@($dataflowDetails | Where-Object { -not (Test-TerminalDataflowStatus $_.status) }).Count -gt 0) {
        if ($stopwatch.Elapsed.TotalHours -gt 11) {
            foreach ($detail in @($dataflowDetails | Where-Object { -not (Test-TerminalDataflowStatus $_.status) })) {
                $detail.status = "Failed"
                $detail.error = "Timed out after 11 hours."
            }
            break
        }
        Start-Sleep -Seconds 30

        foreach ($detail in @($dataflowDetails | Where-Object { -not (Test-TerminalDataflowStatus $_.status) })) {
            try {
                $transactions = Invoke-RestMethod -Method GET -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($detail.workspaceId)/dataflows/$($detail.id)/transactions" -Headers $headers
                $latest = $transactions.value | Sort-Object startTime -Descending | Select-Object -First 1
                if ($latest.status -eq "Success") {
                    $detail.status = "Succeeded"
                    Log "  Dataflow '$($detail.name)' in '$($detail.workspaceName)': succeeded."
                } elseif ($latest.status -eq "Failure") {
                    $detail.status = "Failed"
                    $detail.error = if ($latest.error) { Get-ShortError $latest.error } else { "Power BI reported a failed refresh." }
                    Log "  Dataflow '$($detail.name)' in '$($detail.workspaceName)': FAILED - $($detail.error)"
                }
            } catch {
                $statusCode = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
                if ($statusCode -eq 404) {
                    try {
                        Invoke-RestMethod -Method POST -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($detail.workspaceId)/dataflows/$($detail.id)/refreshes" -Headers $headers -Body '{"notifyOption":"NoNotification"}' | Out-Null
                        $detail.status = "Succeeded"
                        Log "  Dataflow '$($detail.name)' in '$($detail.workspaceName)': succeeded."
                    } catch {
                        $retryStatusCode = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
                        if ($retryStatusCode -eq 400) {
                            Log "  Dataflow '$($detail.name)' in '$($detail.workspaceName)': still running."
                        } else {
                            $detail.status = "Failed"
                            $detail.error = Get-ShortError $_
                            Log "  Dataflow '$($detail.name)' in '$($detail.workspaceName)': FAILED while checking status - $($detail.error)"
                        }
                    }
                } else {
                    $detail.status = "Failed"
                    $detail.error = Get-ShortError $_
                    Log "  Dataflow '$($detail.name)' in '$($detail.workspaceName)': FAILED while checking status - $($detail.error)"
                }
            }
        }

        $succeeded = @($dataflowDetails | Where-Object { $_.status -eq "Succeeded" }).Count
        $failed = @($dataflowDetails | Where-Object { $_.status -eq "Failed" }).Count
        Publish-Status "Running ($succeeded/$($dataflowDetails.Count); $failed failed)" "Pending" $true $dataflowDetails $modelDetails
    }

    $failedDataflows = @($dataflowDetails | Where-Object { $_.status -eq "Failed" })
    if ($failedDataflows.Count -gt 0) {
        $refreshFailed = $true
        foreach ($detail in $failedDataflows) { $refreshErrors.Add("Dataflow '$($detail.name)': $($detail.error)") }
        foreach ($detail in $modelDetails) {
            $detail.status = "Skipped"
            $detail.error = "Not started because one or more dataflows failed."
        }
        Log "Semantic model refreshes were skipped because not all dataflows succeeded."
        Publish-Status "Failed" "Skipped" $true $dataflowDetails $modelDetails
    } else {
        Log "All $($dataflowDetails.Count) dataflow(s) completed successfully."
        Publish-Status "Success" "Pending" $true $dataflowDetails $modelDetails

        Log "=== SEMANTIC MODELS: triggering $($modelDetails.Count) model(s) ==="
        foreach ($detail in $modelDetails) {
            try {
                $response = Invoke-WebRequest -Method POST -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($detail.workspaceId)/datasets/$($detail.id)/refreshes" -Headers $headers -Body '{"type":"Full","commitMode":"transactional"}' -UseBasicParsing
                $locationUrl = [string]$response.Headers["Location"]
                if ([string]::IsNullOrWhiteSpace($locationUrl)) { throw "Power BI accepted the request without a Location header." }
                $detail.requestId = ($locationUrl -split '/')[-1]
                $detail.status = "Running"
                Log "  Semantic model '$($detail.name)' in '$($detail.workspaceName)': running (request $($detail.requestId))."
            } catch {
                $detail.status = "Failed"
                $detail.error = Get-ShortError $_
                Log "  Semantic model '$($detail.name)' in '$($detail.workspaceName)': trigger FAILED - $($detail.error)"
            }
        }
        Publish-Status "Success" "Running" $true $dataflowDetails $modelDetails

        Log "=== SEMANTIC MODELS: polling ==="
        while (@($modelDetails | Where-Object { -not (Test-TerminalModelStatus $_.status) }).Count -gt 0) {
            if ($stopwatch.Elapsed.TotalHours -gt 11) {
                foreach ($detail in @($modelDetails | Where-Object { -not (Test-TerminalModelStatus $_.status) })) {
                    $detail.status = "Failed"
                    $detail.error = "Timed out after 11 hours."
                }
                break
            }
            Start-Sleep -Seconds 30

            foreach ($detail in @($modelDetails | Where-Object { -not (Test-TerminalModelStatus $_.status) })) {
                try {
                    $state = Invoke-RestMethod -Method GET -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($detail.workspaceId)/datasets/$($detail.id)/refreshes/$($detail.requestId)" -Headers $headers
                    switch ([string]$state.status) {
                        "Completed" {
                            $detail.status = "Succeeded"
                            Log "  Semantic model '$($detail.name)' in '$($detail.workspaceName)': succeeded."
                        }
                        "Failed" {
                            $detail.status = "Failed"
                            $detail.error = if ($state.serviceExceptionJson) { Get-ShortError $state.serviceExceptionJson } elseif ($state.extendedStatus) { Get-ShortError $state.extendedStatus } else { "Power BI reported a failed refresh." }
                            Log "  Semantic model '$($detail.name)' in '$($detail.workspaceName)': FAILED - $($detail.error)"
                        }
                        "Disabled" {
                            $detail.status = "Failed"
                            $detail.error = "Refresh is disabled."
                            Log "  Semantic model '$($detail.name)' in '$($detail.workspaceName)': FAILED - refresh is disabled."
                        }
                        "Cancelled" {
                            $detail.status = "Failed"
                            $detail.error = "Refresh was cancelled."
                            Log "  Semantic model '$($detail.name)' in '$($detail.workspaceName)': FAILED - refresh was cancelled."
                        }
                    }
                } catch {
                    $detail.status = "Failed"
                    $detail.error = Get-ShortError $_
                    Log "  Semantic model '$($detail.name)' in '$($detail.workspaceName)': FAILED while checking status - $($detail.error)"
                }
            }

            $succeeded = @($modelDetails | Where-Object { $_.status -eq "Succeeded" }).Count
            $failed = @($modelDetails | Where-Object { $_.status -eq "Failed" }).Count
            Publish-Status "Success" "Running ($succeeded/$($modelDetails.Count); $failed failed)" $true $dataflowDetails $modelDetails
        }

        $failedModels = @($modelDetails | Where-Object { $_.status -eq "Failed" })
        if ($failedModels.Count -gt 0) {
            $refreshFailed = $true
            foreach ($detail in $failedModels) { $refreshErrors.Add("Semantic model '$($detail.name)': $($detail.error)") }
            Publish-Status "Success" "Failed" $true $dataflowDetails $modelDetails
        } else {
            Publish-Status "Success" "Completed" $true $dataflowDetails $modelDetails
        }
    }
} catch {
    $refreshFailed = $true
    $unexpectedError = Get-ShortError $_
    $refreshErrors.Add($unexpectedError)
    Log "ERROR: $unexpectedError"
    foreach ($detail in @($dataflowDetails | Where-Object { $_.status -in @("Pending", "Running") })) {
        $detail.status = "Failed"
        $detail.error = $unexpectedError
    }
    foreach ($detail in @($modelDetails | Where-Object { $_.status -in @("Pending", "Running") })) {
        $detail.status = if (@($dataflowDetails | Where-Object { $_.status -eq "Failed" }).Count -gt 0) { "Skipped" } else { "Failed" }
        $detail.error = $unexpectedError
    }
} finally {
    $endedAt = Get-Date
    try {
        Complete-Notification -DataflowDetails $dataflowDetails -ModelDetails $modelDetails -StartTime $startedAt -EndTime $endedAt
    } catch {
        $warning = "Refresh finished, but the notification could not be prepared: $(Get-ShortError $_)"
        Log "WARNING: $warning"
        Write-RefreshState { param($state) $state.emailStatus = "Failed"; $state.emailWarning = $warning }
    }

    $resultText = if ($refreshFailed) { "Failed" } else { "Succeeded" }
    if ($refreshFailed) {
        Log "COMPLETED WITH ERRORS: $($refreshErrors.Count) refresh error(s)."
    } else {
        Log "SUCCESS: All refreshes completed ($($dataflowDetails.Count) dataflow(s) + $($modelDetails.Count) semantic model(s))."
    }

    Write-RefreshState {
        param($state)
        $state.running = $false
        $state.result = $resultText
        $state.endTime = $endedAt.ToString("o")
        $state.durationSeconds = [math]::Round(($endedAt - $startedAt).TotalSeconds, 1)
        $state.dataflowDetails = @($dataflowDetails)
        $state.semanticModelDetails = @($modelDetails)
        $state.dataflowStatus = if (@($dataflowDetails | Where-Object { $_.status -eq "Failed" }).Count -gt 0) { "Failed" } else { "Success" }
        $state.datasetStatus = if (@($modelDetails | Where-Object { $_.status -eq "Failed" }).Count -gt 0) { "Failed" } elseif (@($modelDetails | Where-Object { $_.status -eq "Skipped" }).Count -gt 0) { "Skipped" } else { "Completed" }
        $state.error = if ($refreshFailed) { $refreshErrors -join " | " } else { "" }
    }
}
