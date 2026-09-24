param(
    [int]$Port = 8765,
    [switch]$NoBrowser
)

$ErrorActionPreference = "SilentlyContinue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$profilesFile = Join-Path $scriptDir "profiles.json"
$htmlFile = Join-Path $scriptDir "index.html"
$statusFile = Join-Path $scriptDir "refresh-status.json"
$rebindStatusFile = Join-Path $scriptDir "rebind-status.json"
$rebindProfilesFile = Join-Path $scriptDir "rebind-profiles.json"
$partitionRefreshProfilesFile = Join-Path $scriptDir "partition-refresh-profiles.json"
$partitionRefreshStatusFile = Join-Path $scriptDir "partition-refresh-status.json"
$logsDir = Join-Path $scriptDir "logs"
$ClientId = "1950a258-227b-4e31-a9cf-717495945fc2"
$PowerBiScope = "https://analysis.windows.net/powerbi/api/.default"
. (Join-Path $scriptDir "partition-refresh.ps1")
$global:partitionSubmissionInProgress = $false

# Ensure logs directory exists
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

# ============================================================
# Optional authentication (Refresh only)
# ============================================================
$global:msalAvailable = $false
try {
    Import-Module MSAL.PS -Force -ErrorAction Stop
    $global:msalAvailable = $true
} catch {
    Write-Host "MSAL.PS is not installed. Rebind is ready; Refresh authentication is unavailable." -ForegroundColor Yellow
    Write-Host "For Refresh, install with: Install-Module -Name MSAL.PS -Scope CurrentUser -Force" -ForegroundColor Gray
}
$global:cachedToken = $null
$tokenFile = Join-Path $scriptDir ".token"
# Treat a cached token as spent this many minutes before it expires. Power BI answers a
# spent bearer token with HTTP 403, which looks identical to a permissions failure.
$tokenExpiryMarginMinutes = 5

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Power BI Dashboard Control Panel" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Rebind starts without authentication. Authenticate from the Refresh tab only if needed." -ForegroundColor Green
Write-Host ""

# ============================================================
# Helpers
# ============================================================
function Test-TokenUsable {
    param([AllowNull()][string]$Candidate)

    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $false }
    try {
        $payload = $Candidate.Split('.')[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) {
            2 { $payload += '==' }
            3 { $payload += '=' }
        }
        $claims = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload)) | ConvertFrom-Json
        return ([DateTimeOffset]::FromUnixTimeSeconds([long]$claims.exp) -gt (Get-Date).ToUniversalTime().AddMinutes($tokenExpiryMarginMinutes))
    } catch {
        return $false
    }
}

function Get-Token {
    param([switch]$Interactive)

    if (-not $global:msalAvailable) { throw "MSAL.PS not installed" }
    if ($global:cachedToken -and (Test-TokenUsable $global:cachedToken)) { return $global:cachedToken }
    $global:cachedToken = $null

    try {
        $t = Get-MsalToken -ClientId $ClientId -TenantId "common" -Scopes $PowerBiScope -Silent -ErrorAction Stop
        $global:cachedToken = $t.AccessToken
    } catch { }

    if ($global:cachedToken) {
        # A refresh worker may outlive the token that launched it and reloads this file.
        @{ Token = $global:cachedToken; Saved = (Get-Date -Format "o") } | ConvertTo-Json | Set-Content -LiteralPath $tokenFile
    }

    if (-not $global:cachedToken -and (Test-Path -LiteralPath $tokenFile)) {
        try {
            $saved = Get-Content -LiteralPath $tokenFile -Raw | ConvertFrom-Json
            if (-not $saved.Token) { throw "Token file is empty" }
            if (-not (Test-TokenUsable $saved.Token)) { throw "Saved token has expired" }
            $headers = @{ Authorization = "Bearer $($saved.Token)" }
            Invoke-RestMethod -Method GET -Uri "https://api.powerbi.com/v1.0/myorg/groups" -Headers $headers -TimeoutSec 10 -ErrorAction Stop | Out-Null
            $global:cachedToken = $saved.Token
        } catch {
            $global:cachedToken = $null
        }
    }

    if (-not $global:cachedToken -and $Interactive) {
        Write-Host ""
        Write-Host "Refresh authentication requested." -ForegroundColor Yellow
        Write-Host "Use the device URL and code shown below. Rebind itself never requires this step." -ForegroundColor Yellow
        $global:cachedToken = (Get-MsalToken -ClientId $ClientId -TenantId "common" -Scopes $PowerBiScope -DeviceCode -ErrorAction Stop).AccessToken
        @{ Token = $global:cachedToken; Saved = (Get-Date -Format "o") } | ConvertTo-Json | Set-Content -LiteralPath $tokenFile
        Write-Host "Authenticated. Refresh is ready." -ForegroundColor Green
    }

    if (-not $global:cachedToken) { throw "Not authenticated" }
    return $global:cachedToken
}

function Serve-StaticFile($response, $filePath, $contentType) {
    if (Test-Path $filePath) {
        $content = [System.IO.File]::ReadAllText($filePath)
        $buf = [System.Text.Encoding]::UTF8.GetBytes($content)
        $response.ContentType = $contentType
        $response.ContentLength64 = $buf.Length
        $response.OutputStream.Write($buf, 0, $buf.Length)
    } else {
        $response.StatusCode = 404
    }
}

function Send-Json($response, $data) {
    $json = $data | ConvertTo-Json -Depth 10 -Compress
    $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
    $response.ContentType = "application/json; charset=utf-8"
    $response.ContentLength64 = $buf.Length
    $response.OutputStream.Write($buf, 0, $buf.Length)
}

function Get-RefreshProfileItems {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return }
    if ($Value -is [System.Array]) {
        foreach ($item in $Value) { Get-RefreshProfileItems $item }
        return
    }

    $propertyNames = @($Value.PSObject.Properties.Name)
    if ($propertyNames -contains "name") {
        Write-Output $Value
        return
    }
    if ($propertyNames -contains "value") {
        Get-RefreshProfileItems $Value.value
    }
}

function Get-UniqueRefreshProfiles {
    param([AllowNull()][object]$Value)

    $profilesByName = [ordered]@{}
    foreach ($profile in @(Get-RefreshProfileItems $Value)) {
        $profileName = ([string]$profile.name).Trim()
        if (-not $profileName) { continue }
        $profilesByName[$profileName.ToLowerInvariant()] = $profile
    }
    return @($profilesByName.Values)
}

function ConvertTo-JsonArray {
    param([AllowNull()][object[]]$Items)

    $serializedItems = @()
    foreach ($item in @($Items)) {
        if ($null -ne $item) { $serializedItems += ($item | ConvertTo-Json -Depth 10 -Compress) }
    }
    return "[" + ($serializedItems -join ",") + "]"
}

function Get-NormalizedRecipients {
    param([AllowNull()][object]$Value)

    $candidates = @()
    foreach ($part in @($Value)) {
        if ($null -ne $part) { $candidates += @([string]$part -split '[,;]') }
    }

    $seen = @{}
    $recipients = @()
    foreach ($candidate in $candidates) {
        $addressText = ([string]$candidate).Trim()
        if (-not $addressText) { continue }
        try {
            $address = New-Object System.Net.Mail.MailAddress($addressText)
            if ($address.Address -ine $addressText) { throw "Display names are not supported" }
        } catch {
            return [pscustomobject]@{ Ok = $false; Error = "Invalid email address: $addressText"; Recipients = @() }
        }
        $key = $address.Address.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $recipients += $address.Address
        }
    }

    return [pscustomobject]@{ Ok = $true; Error = ""; Recipients = @($recipients) }
}

function Get-RefreshRequest {
    param($Body)

    $workspaceId = ([string]$Body.WorkspaceId).Trim()
    $workspaceGuid = [Guid]::Empty
    if (-not [Guid]::TryParse($workspaceId, [ref]$workspaceGuid)) {
        return [pscustomobject]@{ Ok = $false; Error = "Workspace ID must be a valid GUID" }
    }

    $rawDataflows = if ($Body.DataflowIds) { @($Body.DataflowIds) } elseif ($Body.DataflowId) { @($Body.DataflowId) } else { @() }
    $dataflows = @()
    $seenDataflows = @{}
    foreach ($rawDataflow in $rawDataflows) {
        $dataflowId = ([string]$rawDataflow).Trim()
        $dataflowGuid = [Guid]::Empty
        if (-not [Guid]::TryParse($dataflowId, [ref]$dataflowGuid)) {
            return [pscustomobject]@{ Ok = $false; Error = "Every dataflow ID must be a valid GUID" }
        }
        $key = $dataflowGuid.ToString().ToLowerInvariant()
        if (-not $seenDataflows.ContainsKey($key)) {
            $seenDataflows[$key] = $true
            $dataflows += $dataflowGuid.ToString()
        }
    }
    if ($dataflows.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Error = "At least one dataflow is required" }
    }

    $rawModels = if ($Body.SemanticModels) {
        @($Body.SemanticModels)
    } elseif ($Body.DatasetIds) {
        @($Body.DatasetIds | ForEach-Object { [pscustomobject]@{ WorkspaceId = $workspaceId; DatasetId = $_ } })
    } elseif ($Body.DatasetId) {
        @([pscustomobject]@{ WorkspaceId = $workspaceId; DatasetId = $Body.DatasetId })
    } else { @() }

    $models = @()
    $seenModels = @{}
    foreach ($rawModel in $rawModels) {
        $modelWorkspaceId = if ($rawModel.WorkspaceId) { ([string]$rawModel.WorkspaceId).Trim() } else { $workspaceId }
        $datasetId = if ($rawModel.DatasetId) { ([string]$rawModel.DatasetId).Trim() } else { ([string]$rawModel).Trim() }
        $modelWorkspaceGuid = [Guid]::Empty
        $datasetGuid = [Guid]::Empty
        if (-not [Guid]::TryParse($modelWorkspaceId, [ref]$modelWorkspaceGuid) -or -not [Guid]::TryParse($datasetId, [ref]$datasetGuid)) {
            return [pscustomobject]@{ Ok = $false; Error = "Every semantic model must have valid workspace and dataset GUIDs" }
        }
        $key = ($modelWorkspaceGuid.ToString() + "|" + $datasetGuid.ToString()).ToLowerInvariant()
        if (-not $seenModels.ContainsKey($key)) {
            $seenModels[$key] = $true
            $models += [pscustomobject][ordered]@{ WorkspaceId = $modelWorkspaceGuid.ToString(); DatasetId = $datasetGuid.ToString() }
        }
    }
    if ($models.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Error = "At least one semantic model is required" }
    }

    $recipientValue = if ($null -ne $Body.NotificationRecipients) { $Body.NotificationRecipients } else { $Body.NotifyEmails }
    $normalizedRecipients = Get-NormalizedRecipients $recipientValue
    if (-not $normalizedRecipients.Ok) {
        return [pscustomobject]@{ Ok = $false; Error = $normalizedRecipients.Error }
    }

    return [pscustomobject]@{
        Ok = $true
        Error = ""
        WorkspaceId = $workspaceGuid.ToString()
        DataflowIds = @($dataflows)
        SemanticModels = @($models)
        NotificationRecipients = @($normalizedRecipients.Recipients)
        EmailDryRun = ($Body.EmailDryRun -eq $true)
    }
}

function Get-RebindRequest {
    param($Body)

    $rawPath = [string]$Body.ReportPath
    if ([string]::IsNullOrWhiteSpace($rawPath)) {
        return [pscustomobject]@{ Ok = $false; Error = "Report folder path is required" }
    }

    try {
        $resolvedPath = (Resolve-Path -LiteralPath $rawPath -ErrorAction Stop).Path
    } catch {
        return [pscustomobject]@{ Ok = $false; Error = "Report path does not exist: $rawPath" }
    }
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
        return [pscustomobject]@{ Ok = $false; Error = "Report path is not a folder: $rawPath" }
    }

    $hasPbip = @(Get-ChildItem -LiteralPath $resolvedPath -Filter "*.pbip" -File -ErrorAction SilentlyContinue).Count -gt 0
    $hasReport = @(Get-ChildItem -LiteralPath $resolvedPath -Filter "*.Report" -Directory -ErrorAction SilentlyContinue).Count -gt 0
    $hasModel = @(Get-ChildItem -LiteralPath $resolvedPath -Filter "*.SemanticModel" -Directory -ErrorAction SilentlyContinue).Count -gt 0
    if (-not ($hasPbip -or $hasReport -or $hasModel)) {
        return [pscustomobject]@{ Ok = $false; Error = "The selected folder does not look like a PBIP project (no .pbip, .Report, or .SemanticModel item found)" }
    }

    $rawMappings = @($Body.Mappings)
    if ($rawMappings.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Error = "At least one GUID mapping is required" }
    }

    $allowedTypes = @("Workspace", "Dataflow", "Dataset")
    $normalized = @()
    $oldGuids = @{}
    foreach ($mapping in $rawMappings) {
        $type = [string]$mapping.Type
        $oldText = ([string]$mapping.OldGuid).Trim()
        $newText = ([string]$mapping.NewGuid).Trim()
        $oldGuid = [Guid]::Empty
        $newGuid = [Guid]::Empty

        if ($allowedTypes -notcontains $type) {
            return [pscustomobject]@{ Ok = $false; Error = "Unsupported mapping type: $type" }
        }
        if (-not [Guid]::TryParse($oldText, [ref]$oldGuid) -or -not [Guid]::TryParse($newText, [ref]$newGuid)) {
            return [pscustomobject]@{ Ok = $false; Error = "Every mapping must contain a valid old and new GUID" }
        }

        $oldValue = $oldGuid.ToString().ToLowerInvariant()
        $newValue = $newGuid.ToString().ToLowerInvariant()
        if ($oldValue -eq $newValue) {
            return [pscustomobject]@{ Ok = $false; Error = "$type mapping has the same old and new GUID" }
        }
        if ($oldGuids.ContainsKey($oldValue)) {
            return [pscustomobject]@{ Ok = $false; Error = "Old GUID is mapped more than once: $oldValue" }
        }

        $oldGuids[$oldValue] = $true
        $normalized += [pscustomobject]@{ Type = $type; OldGuid = $oldValue; NewGuid = $newValue }
    }

    foreach ($mapping in $normalized) {
        if ($oldGuids.ContainsKey($mapping.NewGuid)) {
            return [pscustomobject]@{ Ok = $false; Error = "A new GUID is also used as an old GUID. Chained mappings are unsafe; split them into separate rebind runs." }
        }
    }

    $signatureParts = @($normalized | ForEach-Object { "$($_.Type)|$($_.OldGuid)|$($_.NewGuid)" } | Sort-Object)
    $signatureInput = $resolvedPath.ToLowerInvariant() + "`n" + ($signatureParts -join "`n")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $signatureBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($signatureInput))
        $signature = ([BitConverter]::ToString($signatureBytes)).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }

    return [pscustomobject]@{
        Ok = $true
        Error = ""
        ReportPath = $resolvedPath
        Mappings = $normalized
        Signature = $signature
    }
}

function ConvertTo-Base64Json($Data) {
    $json = $Data | ConvertTo-Json -Depth 10 -Compress
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Get-RebindState {
    if (-not (Test-Path -LiteralPath $rebindStatusFile)) { return $null }
    try { return Get-Content -LiteralPath $rebindStatusFile -Raw | ConvertFrom-Json } catch { return $null }
}

function Set-RebindFailure($Message) {
    $state = Get-RebindState
    if (-not $state) {
        $state = [pscustomobject]@{ phase = "failed"; running = $false; error = ""; logs = @(); scanResults = $null; applyResults = $null }
    }
    $state.phase = "failed"
    $state.running = $false
    $state.error = $Message
    $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $rebindStatusFile
}

# ============================================================
# Start HTTP listener
# ============================================================
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()

Write-Host "Dashboard running at: http://localhost:$Port" -ForegroundColor Yellow
Write-Host "Do not close this window - it is the server." -ForegroundColor Gray
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (-not $NoBrowser) { Start-Process "http://localhost:$Port" }

# Clear stale status files
@{ running = $false; result = ""; logs = @(); dataflowStatus = ""; datasetStatus = ""; dataflowDetails = @(); semanticModelDetails = @(); emailStatus = ""; emailWarning = ""; error = "" } | ConvertTo-Json -Depth 10 | Set-Content $statusFile
@{ phase = "idle"; running = $false; error = ""; logs = @() } | ConvertTo-Json -Depth 10 | Set-Content $rebindStatusFile
if (-not (Test-Path -LiteralPath $partitionRefreshStatusFile)) {
    @{ running = $false; requestId = ""; status = ""; extendedStatus = ""; logs = @(); partitions = @() } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $partitionRefreshStatusFile
}

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response
    $path = $request.Url.AbsolutePath
    $method = $request.HttpMethod

    try {
        $origin = $request.Headers["Origin"]
        $expectedOrigin = "http://localhost:$Port"
        if ($origin -and $origin -ne $expectedOrigin) {
            $response.StatusCode = 403
            Send-Json $response @{ ok = $false; error = "Cross-origin requests are not allowed" }
            continue
        }

        switch -Regex ($path) {
            "^/$" {
                Serve-StaticFile $response $htmlFile "text/html; charset=utf-8"
            }
            "^/favicon\.(png|ico)$" {
                $fp = Join-Path $scriptDir "favicon.png"
                if (Test-Path $fp) {
                    $bytes = [System.IO.File]::ReadAllBytes($fp)
                    $response.ContentType = "image/png"
                    $response.ContentLength64 = $bytes.Length
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                } else { $response.StatusCode = 404 }
            }
            "^/api/profiles$" {
                if ($method -eq "GET") {
                    $profiles = if (Test-Path $profilesFile) {
                        Get-Content $profilesFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    } else { @() }
                    $items = @(Get-UniqueRefreshProfiles $profiles)
                    $json = ConvertTo-JsonArray $items
                    $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buf.Length
                    $response.OutputStream.Write($buf, 0, $buf.Length)
                } elseif ($method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream)
                    $json = $reader.ReadToEnd(); $reader.Close()
                    try {
                        $parsedProfiles = $json | ConvertFrom-Json -ErrorAction Stop
                        $submittedProfiles = @(Get-UniqueRefreshProfiles $parsedProfiles)
                    } catch {
                        $response.StatusCode = 400
                        Send-Json $response @{ ok = $false; error = "Invalid profile JSON" }
                        continue
                    }
                    $profileError = ""
                    foreach ($profile in $submittedProfiles) {
                        $normalized = Get-NormalizedRecipients $profile.NotifyEmails
                        if (-not $normalized.Ok) {
                            $profileError = "Profile '$([string]$profile.name)': $($normalized.Error)"
                            break
                        }
                        if ($profile.PSObject.Properties.Name -contains "NotifyEmails") {
                            $profile.NotifyEmails = $normalized.Recipients -join ", "
                        } else {
                            $profile | Add-Member -NotePropertyName NotifyEmails -NotePropertyValue ($normalized.Recipients -join ", ")
                        }
                    }
                    if ($profileError) {
                        $response.StatusCode = 400
                        Send-Json $response @{ ok = $false; error = $profileError }
                        continue
                    }
                    $json = ConvertTo-JsonArray $submittedProfiles
                    [System.IO.File]::WriteAllText($profilesFile, $json, (New-Object System.Text.UTF8Encoding $true))
                    Send-Json $response @{ ok = $true }
                }
            }
            "^/api/auth/status$" {
                if ($method -ne "GET") { $response.StatusCode = 405; continue }
                $authError = ""
                try { Get-Token | Out-Null } catch { $authError = $_.Exception.Message }
                Send-Json $response @{
                    authenticated = ($global:cachedToken -ne $null)
                    msalAvailable = $global:msalAvailable
                    error = $authError
                }
            }
            "^/api/auth/login$" {
                if ($method -ne "POST") { $response.StatusCode = 405; continue }
                try {
                    Get-Token -Interactive | Out-Null
                    Send-Json $response @{ ok = $true; authenticated = $true }
                } catch {
                    $response.StatusCode = 401
                    Send-Json $response @{ ok = $false; authenticated = $false; error = $_.Exception.Message }
                }
            }
            "^/api/refresh/start$" {
                if ($method -ne "POST") { $response.StatusCode = 405; continue }

                $current = if (Test-Path $statusFile) { Get-Content $statusFile -Raw | ConvertFrom-Json } else { $null }
                if ($current -and $current.running) {
                    Send-Json $response @{ ok = $false; error = "A refresh is already running" }
                    continue
                }

                $reader = New-Object System.IO.StreamReader($request.InputStream)
                try { $body = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop } catch {
                    $reader.Close()
                    $response.StatusCode = 400
                    Send-Json $response @{ ok = $false; error = "Invalid refresh request JSON" }
                    continue
                }
                $reader.Close()

                $refreshRequest = Get-RefreshRequest $body
                if (-not $refreshRequest.Ok) {
                    $response.StatusCode = 400
                    Send-Json $response @{ ok = $false; error = $refreshRequest.Error }
                    continue
                }

                try {
                    $tokenForWorker = Get-Token
                } catch {
                    $response.StatusCode = 401
                    Send-Json $response @{ ok = $false; error = "Refresh requires authentication. Use Authenticate for Refresh first." }
                    continue
                }

                # Read template and substitute placeholders
                $templatePath = Join-Path $scriptDir "_refresh-worker-template.ps1"
                $emailModulePath = Join-Path $scriptDir "refresh-email.ps1"
                if (-not (Test-Path $templatePath) -or -not (Test-Path $emailModulePath)) {
                    Send-Json $response @{ ok = $false; error = "Refresh worker or email module was not found" }
                    continue
                }
                $payload = [ordered]@{
                    WorkspaceId = $refreshRequest.WorkspaceId
                    DataflowIds = @($refreshRequest.DataflowIds)
                    SemanticModels = @($refreshRequest.SemanticModels)
                    NotificationRecipients = @($refreshRequest.NotificationRecipients)
                    EmailDryRun = $refreshRequest.EmailDryRun
                } | ConvertTo-Json -Depth 10 -Compress
                $payloadBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payload))
                $workerScript = [System.IO.File]::ReadAllText($templatePath)
                $workerScript = $workerScript.Replace("{{StatusFile}}", $statusFile)
                $workerScript = $workerScript.Replace("{{LogsDir}}", $logsDir)
                $workerScript = $workerScript.Replace("{{EmailModule}}", $emailModulePath)
                $workerScript = $workerScript.Replace("{{TokenFile}}", $tokenFile)
                $workerScript = $workerScript.Replace("{{RefreshPayload}}", $payloadBase64)
                $workerScript = $workerScript.Replace("{{Token}}", $tokenForWorker)

                # Validate: must have replaced all placeholders
                if ($workerScript -match '\{\{') {
                    Send-Json $response @{ ok = $false; error = "Worker template has unreplaced placeholders" }
                    continue
                }
                if ($workerScript.Length -lt 200) {
                    Send-Json $response @{ ok = $false; error = "Worker script too short ($($workerScript.Length) chars) -- template likely broken" }
                    continue
                }

                $workerPath = Join-Path $scriptDir "_worker.ps1"
                [System.IO.File]::WriteAllText($workerPath, $workerScript, (New-Object System.Text.UTF8Encoding $true))

                if (-not (Test-Path $workerPath) -or (Get-Item $workerPath).Length -lt 200) {
                    Send-Json $response @{ ok = $false; error = "Failed to write worker script" }
                    continue
                }

                [ordered]@{
                    running = $true; result = "Starting"; startTime = (Get-Date -Format "o"); endTime = ""; durationSeconds = 0
                    logs = @(); dataflowStatus = "Pending"; datasetStatus = "Pending"; dataflowDetails = @(); semanticModelDetails = @()
                    emailStatus = if ($refreshRequest.NotificationRecipients.Count -gt 0) { "Pending" } else { "Skipped" }
                    emailWarning = ""; error = ""
                } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statusFile

                $errorLog = Join-Path $logsDir "refresh-worker-errors.log"
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "powershell.exe"
                $psi.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$workerPath`" 2>`"$errorLog`""
                $psi.CreateNoWindow = $true
                $psi.UseShellExecute = $false
                $proc = [System.Diagnostics.Process]::Start($psi)
                if (-not $proc) {
                    @{ running = $false; result = "Failed"; logs = @(); dataflowStatus = ""; datasetStatus = ""; dataflowDetails = @(); semanticModelDetails = @(); emailStatus = ""; emailWarning = ""; error = "Failed to start worker process" } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statusFile
                    Send-Json $response @{ ok = $false; error = "Failed to start worker process" }
                    continue
                }

                Send-Json $response @{ ok = $true }
            }
            "^/api/refresh/status$" {
                if ($method -ne "GET") { $response.StatusCode = 405; continue }
                if (Test-Path $statusFile) {
                    $s = Get-Content $statusFile -Raw | ConvertFrom-Json
                    Send-Json $response $s
                } else {
                    Send-Json $response @{ running = $false; result = ""; logs = @(); dataflowStatus = ""; datasetStatus = ""; dataflowDetails = @(); semanticModelDetails = @(); emailStatus = ""; emailWarning = ""; error = "" }
                }
            }

            # ============================================================
            # PARTITION REFRESH
            # ============================================================
            "^/api/partition-refresh-profiles$" {
                if ($method -eq "GET") {
                    $items = if ((Test-Path -LiteralPath $partitionRefreshProfilesFile) -and (Get-Item -LiteralPath $partitionRefreshProfilesFile).Length -gt 0) {
                        try { @(Get-Content -LiteralPath $partitionRefreshProfilesFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { @() }
                    } else { @() }
                    $profilesJson = ConvertTo-Json -InputObject @($items) -Depth 10 -Compress
                    $profilesBuffer = [System.Text.Encoding]::UTF8.GetBytes($profilesJson)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $profilesBuffer.Length
                    $response.OutputStream.Write($profilesBuffer, 0, $profilesBuffer.Length)
                } elseif ($method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream)
                    $rawJson = $reader.ReadToEnd(); $reader.Close()
                    try {
                        $parsedProfiles = $rawJson | ConvertFrom-Json
                        $profiles = if ($null -eq $parsedProfiles) { @() } else { @($parsedProfiles) }
                    } catch {
                        $response.StatusCode = 400; Send-Json $response @{ ok = $false; error = "Invalid profile JSON" }; continue
                    }
                    $profileError = ""
                    foreach ($profile in $profiles) {
                        $validated = Get-PartitionRefreshRequest $profile
                        if (-not $validated.Ok) {
                            $profileError = "Invalid profile '$([string]$profile.name)': $($validated.Error)"
                            break
                        }
                    }
                    if ($profileError) { $response.StatusCode = 400; Send-Json $response @{ ok = $false; error = $profileError }; continue }
                    $profilesJson = ConvertTo-Json -InputObject @($profiles) -Depth 10
                    [System.IO.File]::WriteAllText($partitionRefreshProfilesFile, $profilesJson, (New-Object System.Text.UTF8Encoding $true))
                    Send-Json $response @{ ok = $true }
                } else { $response.StatusCode = 405 }
            }
            "^/api/partition-refresh/start$" {
                if ($method -ne "POST") { $response.StatusCode = 405; continue }
                if ($global:partitionSubmissionInProgress) {
                    $response.StatusCode = 409; Send-Json $response @{ ok = $false; error = "A partition refresh submission is already in progress" }; continue
                }
                $existing = if (Test-Path -LiteralPath $partitionRefreshStatusFile) { try { Get-Content -LiteralPath $partitionRefreshStatusFile -Raw | ConvertFrom-Json } catch { $null } } else { $null }
                if ($existing -and $existing.running) {
                    $response.StatusCode = 409; Send-Json $response @{ ok = $false; error = "The current partition refresh is still in progress" }; continue
                }

                $reader = New-Object System.IO.StreamReader($request.InputStream)
                try { $body = $reader.ReadToEnd() | ConvertFrom-Json } catch {
                    $reader.Close(); $response.StatusCode = 400; Send-Json $response @{ ok = $false; error = "Invalid request JSON" }; continue
                }
                $reader.Close()
                $validated = Get-PartitionRefreshRequest $body
                if (-not $validated.Ok) {
                    $response.StatusCode = 400; Send-Json $response @{ ok = $false; error = $validated.Error }; continue
                }
                try { $token = Get-Token } catch {
                    $response.StatusCode = 401; Send-Json $response @{ ok = $false; error = "Partition Refresh requires authentication. Use Authenticate for Refresh first." }; continue
                }

                $global:partitionSubmissionInProgress = $true
                try {
                    $uri = "https://api.powerbi.com/v1.0/myorg/groups/$($validated.WorkspaceId)/datasets/$($validated.DatasetId)/refreshes"
                    $headers = @{ Authorization = "Bearer $token" }
                    $payloadJson = $validated.Payload | ConvertTo-Json -Depth 10 -Compress
                    $webResult = Invoke-WebRequest -UseBasicParsing -Method POST -Uri $uri -Headers $headers -ContentType "application/json" -Body $payloadJson -ErrorAction Stop
                    $requestId = Get-PowerBiRequestId $webResult
                    if (-not $requestId) { throw "Power BI accepted the request but did not return a request ID" }
                    $submitted = [DateTime]::UtcNow.ToString("o")
                    $state = [ordered]@{
                        running = $true; workspaceId = $validated.WorkspaceId; datasetId = $validated.DatasetId
                        requestId = $requestId; tableName = $validated.TableName; partitions = $validated.Partitions
                        submittedAt = $submitted; status = "Unknown"; extendedStatus = "InProgress"
                        startTime = ""; endTime = ""; attempts = @(); objects = @(); messages = @()
                        error = ""; logs = @([ordered]@{ time = (Get-Date -Format "HH:mm:ss"); text = "Request accepted. Processing continues in Power BI Service." })
                    }
                    $state | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $partitionRefreshStatusFile -Encoding UTF8
                    Send-Json $response @{ ok = $true; requestId = $requestId; submittedAt = $submitted }
                } catch {
                    $response.StatusCode = 502
                    Send-Json $response @{ ok = $false; error = "Power BI rejected the partition refresh request: $($_.Exception.Message)" }
                } finally { $global:partitionSubmissionInProgress = $false }
            }
            "^/api/partition-refresh/status$" {
                if ($method -ne "GET") { $response.StatusCode = 405; continue }
                $state = if (Test-Path -LiteralPath $partitionRefreshStatusFile) { try { Get-Content -LiteralPath $partitionRefreshStatusFile -Raw | ConvertFrom-Json } catch { $null } } else { $null }
                if (-not $state -or -not $state.requestId) {
                    Send-Json $response @{ running = $false; requestId = ""; status = ""; extendedStatus = ""; logs = @(); partitions = @() }; continue
                }
                try { $token = Get-Token } catch {
                    $response.StatusCode = 401
                    Send-Json $response @{ ok = $false; authenticationRequired = $true; error = "Authenticate again to view status. The accepted refresh continues server-side."; state = $state }; continue
                }
                try {
                    $headers = @{ Authorization = "Bearer $token" }
                    $uri = "https://api.powerbi.com/v1.0/myorg/groups/$($state.workspaceId)/datasets/$($state.datasetId)/refreshes/$($state.requestId)"
                    $remote = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
                    foreach ($property in @("status", "extendedStatus", "startTime", "endTime", "attempts", "objects", "messages")) {
                        if ($null -ne $remote.$property) { $state.$property = $remote.$property }
                    }
                    $state.running = -not (Test-PartitionRefreshTerminalStatus $state)
                    $state | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $partitionRefreshStatusFile -Encoding UTF8
                    Send-Json $response $state
                } catch {
                    $response.StatusCode = 502; Send-Json $response @{ ok = $false; error = "Could not retrieve partition refresh status: $($_.Exception.Message)"; state = $state }
                }
            }
            "^/api/partition-refresh/history$" {
                if ($method -ne "GET") { $response.StatusCode = 405; continue }
                $state = if (Test-Path -LiteralPath $partitionRefreshStatusFile) { try { Get-Content -LiteralPath $partitionRefreshStatusFile -Raw | ConvertFrom-Json } catch { $null } } else { $null }
                $workspaceText = [string]$request.QueryString["workspaceId"]
                $datasetText = [string]$request.QueryString["datasetId"]
                if (-not $workspaceText -and $state) { $workspaceText = [string]$state.workspaceId }
                if (-not $datasetText -and $state) { $datasetText = [string]$state.datasetId }
                $workspaceGuid = [Guid]::Empty; $datasetGuid = [Guid]::Empty
                if (-not [Guid]::TryParse($workspaceText, [ref]$workspaceGuid) -or -not [Guid]::TryParse($datasetText, [ref]$datasetGuid)) {
                    $response.StatusCode = 400; Send-Json $response @{ ok = $false; error = "Valid workspace and dataset IDs are required" }; continue
                }
                try { $token = Get-Token } catch {
                    $response.StatusCode = 401; Send-Json $response @{ ok = $false; error = "Authenticate again to view refresh history" }; continue
                }
                try {
                    $headers = @{ Authorization = "Bearer $token" }
                    $uri = "https://api.powerbi.com/v1.0/myorg/groups/$workspaceGuid/datasets/$datasetGuid/refreshes?`$top=10"
                    $history = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
                    Send-Json $response @{ ok = $true; value = @($history.value) }
                } catch {
                    $response.StatusCode = 502; Send-Json $response @{ ok = $false; error = "Could not retrieve refresh history: $($_.Exception.Message)" }
                }
            }

            # ============================================================
            # REBIND -- Profiles
            # ============================================================
            "^/api/rebind-profiles$" {
                if ($method -eq "GET") {
                    $profiles = if ((Test-Path $rebindProfilesFile) -and (Get-Item $rebindProfilesFile).Length -gt 0) {
                        try { @(Get-Content $rebindProfilesFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { @() }
                    } else { @() }
                    $items = @($profiles)
                    $json = "["
                    for ($i = 0; $i -lt $items.Count; $i++) {
                        if ($i -gt 0) { $json += "," }
                        $json += ($items[$i] | ConvertTo-Json -Depth 10 -Compress)
                    }
                    $json += "]"
                    $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buf.Length
                    $response.OutputStream.Write($buf, 0, $buf.Length)
                } elseif ($method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream)
                    $json = $reader.ReadToEnd(); $reader.Close()
                    [System.IO.File]::WriteAllText($rebindProfilesFile, $json, (New-Object System.Text.UTF8Encoding $true))
                    Send-Json $response @{ ok = $true }
                }
            }

            # ============================================================
            # REBIND -- Folder picker
            # ============================================================
            "^/api/pick-folder$" {
                try {
                    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
                    $dialog.Description = "Select the PBIP report folder"
                    $dialog.ShowNewFolderButton = $false
                    $dialog.RootFolder = [Environment+SpecialFolder]::MyComputer
                    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                        Send-Json $response @{ path = $dialog.SelectedPath }
                    } else {
                        Send-Json $response @{ path = $null }
                    }
                } catch {
                    Send-Json $response @{ path = $null; error = $_.Exception.Message }
                }
            }

            # ============================================================
            # REBIND -- Scan (Phase 1)
            # ============================================================
            "^/api/rebind/scan$" {
                if ($method -ne "POST") { $response.StatusCode = 405; continue }

                $reader = New-Object System.IO.StreamReader($request.InputStream)
                $body = $reader.ReadToEnd() | ConvertFrom-Json; $reader.Close()

                $requestData = Get-RebindRequest $body
                if (-not $requestData.Ok) {
                    Send-Json $response @{ ok = $false; error = $requestData.Error }
                    continue
                }

                $currentState = Get-RebindState
                if ($currentState -and $currentState.running) {
                    Send-Json $response @{ ok = $false; error = "Another rebind operation is already running" }
                    continue
                }

                $reportPath = $requestData.ReportPath
                $payloadBase64 = ConvertTo-Base64Json @{
                    ReportPath = $reportPath
                    StatusFile = $rebindStatusFile
                    LogsDir = $logsDir
                    Mappings = @($requestData.Mappings)
                    RequestSignature = $requestData.Signature
                }

                @{ phase = "starting_scan"; running = $true; error = ""; logs = @(); scanResults = $null; applyResults = $null; requestSignature = $requestData.Signature } |
                    ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $rebindStatusFile

                # Generate scan worker with FIXED file enumeration (no broken -Include)
                $rebindWorker = @"
`$ErrorActionPreference = "Stop"
`$payload = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("$payloadBase64")) | ConvertFrom-Json
`$reportPath = `$payload.ReportPath
`$rebindStatusFile = `$payload.StatusFile
`$logsDir = `$payload.LogsDir
`$mappings = @(`$payload.Mappings)
`$requestSignature = `$payload.RequestSignature

function Log(`$msg) {
    try {
        `$s = Get-Content `$rebindStatusFile -Raw | ConvertFrom-Json
        `$s.logs += @{ time = (Get-Date -Format "HH:mm:ss"); text = `$msg }
        `$s | ConvertTo-Json -Depth 10 -Compress | Set-Content `$rebindStatusFile
    } catch { }
}

function SetPhase(`$phase) {
    try {
        `$s = Get-Content `$rebindStatusFile -Raw | ConvertFrom-Json
        `$s.phase = `$phase
        `$s.running = (`$phase -ne 'scan_done' -and `$phase -ne 'done' -and `$phase -ne 'failed')
        `$s | ConvertTo-Json -Depth 10 -Compress | Set-Content `$rebindStatusFile
    } catch { }
}

function Write-ScanResults(`$results) {
    try {
        `$s = Get-Content `$rebindStatusFile -Raw | ConvertFrom-Json
        `$s.scanResults = `$results
        `$s | ConvertTo-Json -Depth 10 -Compress | Set-Content `$rebindStatusFile
    } catch { }
}

try {
    # Initialize
    @{ phase = "scanning"; running = `$true; error = ""; logs = @(); scanResults = `$null; applyResults = `$null; requestSignature = `$requestSignature } | ConvertTo-Json -Depth 10 | Set-Content `$rebindStatusFile
    Log "=== SCAN ==="
    Log "Path: `$reportPath"
    Log "Mappings: `$(`$mappings.Count)"

    # Confirm PBIP structure
    `$hasReport = Test-Path (Join-Path `$reportPath "*.Report")
    `$hasModel = Test-Path (Join-Path `$reportPath "*.SemanticModel")
    `$hasPbip = (Get-ChildItem `$reportPath -Filter "*.pbip" -File).Count -gt 0
    Log "PBIP structure: Report=`$hasReport, SemanticModel=`$hasModel, .pbip=`$hasPbip"

    # Find all target files (skip .pbi/ cache, skip generated files)
    # Using -File + Where-Object extension filter instead of -Include (broken in PS 5.1 with -Recurse)
    `$allFiles = Get-ChildItem -Path `$reportPath -Recurse -File |
        Where-Object { (`$_.Extension -eq '.tmdl' -or `$_.Extension -eq '.json') -and `$_.FullName -notmatch '\\\.pbi[\\/]' -and `$_.FullName -notmatch '\\cache\.abf`$' -and `$_.DirectoryName -notmatch '\\\.pbi`$' }

    Log "Target files found: `$(`$allFiles.Count)"
    if (-not `$allFiles) { `$allFiles = @() }

    `$scanMappings = @()
    `$newGuidPresence = @()
    `$scannedFiles = @()

    foreach (`$m in `$mappings) {
        `$oldGuid = `$m.OldGuid
        `$newGuid = `$m.NewGuid
        `$mappingType = `$m.Type

        Log "---"
        Log "Scan `${mappingType}`: `$(`$oldGuid.Substring(0,8))..."

        `$occurrences = @()
        `$totalCount = 0

        foreach (`$file in `$allFiles) {
            `$matches = Select-String -Path `$file.FullName -Pattern ([regex]::Escape(`$oldGuid)) -CaseSensitive:`$false -AllMatches
            if (`$matches) {
                `$count = 0
                `$contextLines = @()
                foreach (`$match in `$matches) {
                    `$count += `$match.Matches.Count
                    # Capture context (2 lines of context)
                    `$relPath = `$file.FullName.Substring(`$reportPath.Length).TrimStart('\','/')
                    `$ctx = "`${relPath}`:`$(`$match.LineNumber): `$(`$match.Line.Trim())"
                    if (`$contextLines.Count -lt 2) { `$contextLines += `$ctx }
                }
                `$totalCount += `$count
                `$occurrences += @{
                    file = `$file.FullName.Substring(`$reportPath.Length).TrimStart('\','/')
                    count = `$count
                    context = `$contextLines
                }
                if (`$scannedFiles -notcontains `$file.FullName) { `$scannedFiles += `$file.FullName }
            }
        }

        Log "  `$totalCount hit(s) in `$(`$occurrences.Count) file(s)"

        # Show per-file breakdown
        foreach (`$occ in `$occurrences) {
            Log "  `$(`$occ.file): `$(`$occ.count) hit(s)"
            foreach (`$ctx in `$occ.context) {
                Log "    `$ctx"
            }
        }

        # Check for new GUID already present
        `$newMatches = if (`$allFiles.Count -gt 0) {
            @(Select-String -Path `$allFiles.FullName -Pattern ([regex]::Escape(`$newGuid)) -CaseSensitive:`$false -List)
        } else { @() }
        if (`$newMatches) {
            Log "  WARN: new GUID `$(`$newGuid.Substring(0,8))... already in:"
            foreach (`$nm in `$newMatches) {
                `$relP = `$nm.Path.Substring(`$reportPath.Length).TrimStart('\','/')
                Log "    `${relP}`:`$(`$nm.LineNumber): `$(`$nm.Line.Trim())"
                `$newGuidPresence += @{ guid = `$newGuid; file = `$relP; line = `$nm.LineNumber }
            }
        }

        `$scanMappings += @{
            type = `$mappingType
            oldGuid = `$oldGuid
            newGuid = `$newGuid
            totalOccurrences = `$totalCount
            occurrences = `$occurrences
            ambiguous = @()
        }
    }

    # Check for ambiguous GUIDs (appearing in unexpected contexts)
    Log "---"
    Log "Ambiguity check..."
    # Ambiguous: GUIDs that appear in files that aren't .tmdl or report JSON
    foreach (`$m in `$scanMappings) {
        foreach (`$occ in `$m.occurrences) {
            `$ext = [System.IO.Path]::GetExtension(`$occ.file).ToLower()
            if (`$ext -eq '.json' -and `$occ.file -notmatch 'Report') {
                Log "  WARN: `$(`$m.oldGuid.Substring(0,8))... in non-Report JSON: `$(`$occ.file)"
                `$m.ambiguous += @{ file = `$occ.file; reason = "Non-report JSON file" }
            }
        }
    }

    `$results = @{
        mappings = `$scanMappings
        newGuidPresence = `$newGuidPresence
        scannedFiles = (`$scannedFiles | ForEach-Object { `$_.Substring(`$reportPath.Length).TrimStart('\','/') })
        targetFileCount = `$allFiles.Count
        matchedFileCount = `$scannedFiles.Count
    }

    Write-ScanResults `$results

    Log "---"
    Log "SCAN DONE: `$(`$scanMappings.Count) mapping(s), `$(`$scannedFiles.Count) file(s)"
    Log "Total hits: `$(`$(`$scanMappings | ForEach-Object { `$_.totalOccurrences } | Measure-Object -Sum).Sum)"

    if (`$newGuidPresence.Count -gt 0) {
        Log "WARN: `$(`$newGuidPresence.Count) new GUID(s) already present"
    }

    Log "=== Review scan results, then click Apply to proceed ==="
    SetPhase "scan_done"

} catch {
    Log "ERROR during scan: `$_"
    try {
        `$s = Get-Content `$rebindStatusFile -Raw | ConvertFrom-Json
        `$s.error = `$_.Exception.Message
        `$s.phase = "failed"
        `$s.running = `$false
        `$s | ConvertTo-Json -Depth 10 -Compress | Set-Content `$rebindStatusFile
    } catch { }
}
"@
                $rebindWorkerPath = Join-Path $scriptDir "_rebind-worker.ps1"
                [System.IO.File]::WriteAllText($rebindWorkerPath, $rebindWorker, (New-Object System.Text.UTF8Encoding $true))

                if (-not (Test-Path $rebindWorkerPath)) {
                    Set-RebindFailure "Failed to write scan worker"
                    Send-Json $response @{ ok = $false; error = "Failed to write scan worker" }
                    continue
                }

                $errorLog = Join-Path $logsDir "rebind-worker-errors.log"
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "powershell.exe"
                $psi.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$rebindWorkerPath`" 2>`"$errorLog`""
                $psi.CreateNoWindow = $true
                $psi.UseShellExecute = $false
                $proc = [System.Diagnostics.Process]::Start($psi)
                if (-not $proc) {
                    Set-RebindFailure "Failed to start scan worker"
                    Send-Json $response @{ ok = $false; error = "Failed to start scan worker" }
                    continue
                }

                Send-Json $response @{ ok = $true }
            }

            # ============================================================
            # REBIND -- Apply (Phase 2 + 3)
            # ============================================================
            "^/api/rebind/apply$" {
                if ($method -ne "POST") { $response.StatusCode = 405; continue }

                $reader = New-Object System.IO.StreamReader($request.InputStream)
                $body = $reader.ReadToEnd() | ConvertFrom-Json; $reader.Close()

                $requestData = Get-RebindRequest $body
                if (-not $requestData.Ok) {
                    Send-Json $response @{ ok = $false; error = $requestData.Error }
                    continue
                }

                $currentState = Get-RebindState
                if (-not $currentState -or $currentState.running -or $currentState.phase -ne "scan_done") {
                    Send-Json $response @{ ok = $false; error = "Run Scan and review its summary before applying changes" }
                    continue
                }
                if ($currentState.requestSignature -ne $requestData.Signature) {
                    Send-Json $response @{ ok = $false; error = "The path or mappings changed after Scan. Run Scan again before applying." }
                    continue
                }

                $scanMappings = @($currentState.scanResults.mappings)
                $scanHits = ($scanMappings | ForEach-Object { [int]$_.totalOccurrences } | Measure-Object -Sum).Sum
                if (-not $scanHits -or $scanHits -le 0) {
                    Send-Json $response @{ ok = $false; error = "Scan found no old GUID occurrences, so there is nothing to apply" }
                    continue
                }

                $reportPath = $requestData.ReportPath
                $payloadBase64 = ConvertTo-Base64Json @{
                    ReportPath = $reportPath
                    StatusFile = $rebindStatusFile
                    LogsDir = $logsDir
                    Mappings = @($requestData.Mappings)
                    RequestSignature = $requestData.Signature
                }

                @{ phase = "starting_apply"; running = $true; error = ""; logs = @(); scanResults = $currentState.scanResults; applyResults = $null; requestSignature = $requestData.Signature } |
                    ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $rebindStatusFile

                # Generate apply worker (Phase 2: replace + Phase 3: verify)
                $rebindWorker = @"
`$ErrorActionPreference = "Stop"
`$payload = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("$payloadBase64")) | ConvertFrom-Json
`$reportPath = `$payload.ReportPath
`$rebindStatusFile = `$payload.StatusFile
`$logsDir = `$payload.LogsDir
`$mappings = @(`$payload.Mappings)
`$requestSignature = `$payload.RequestSignature

function Log(`$msg) {
    try {
        `$s = Get-Content `$rebindStatusFile -Raw | ConvertFrom-Json
        `$s.logs += @{ time = (Get-Date -Format "HH:mm:ss"); text = `$msg }
        `$s | ConvertTo-Json -Depth 10 -Compress | Set-Content `$rebindStatusFile
    } catch { }
}

function SetPhase(`$phase) {
    try {
        `$s = Get-Content `$rebindStatusFile -Raw | ConvertFrom-Json
        `$s.phase = `$phase
        `$s.running = (`$phase -ne 'done' -and `$phase -ne 'failed')
        `$s | ConvertTo-Json -Depth 10 -Compress | Set-Content `$rebindStatusFile
    } catch { }
}

function Write-ApplyResults(`$results) {
    try {
        `$s = Get-Content `$rebindStatusFile -Raw | ConvertFrom-Json
        `$s.applyResults = `$results
        `$s | ConvertTo-Json -Depth 10 -Compress | Set-Content `$rebindStatusFile
    } catch { }
}

try {
    @{ phase = "replacing"; running = `$true; error = ""; logs = @(); scanResults = `$null; applyResults = `$null; requestSignature = `$requestSignature } | ConvertTo-Json -Depth 10 | Set-Content `$rebindStatusFile
    Log "=== REPLACE ==="
    Log "Path: `$reportPath"
    Log "Mappings: `$(`$mappings.Count)"

    # Collect all target files
    `$allFiles = Get-ChildItem -Path `$reportPath -Recurse -File |
        Where-Object { (`$_.Extension -eq '.tmdl' -or `$_.Extension -eq '.json') -and `$_.FullName -notmatch '\\\.pbi[\\/]' -and `$_.FullName -notmatch '\\cache\.abf`$' -and `$_.DirectoryName -notmatch '\\\.pbi`$' }
    if (-not `$allFiles) { `$allFiles = @() }

    `$filesChanged = @()
    `$totalReplacements = 0
    `$mappingResults = @()

    # Process one mapping at a time to avoid cross-contamination
    foreach (`$m in `$mappings) {
        `$oldGuid = `$m.OldGuid
        `$newGuid = `$m.NewGuid
        `$mappingType = `$m.Type

        Log "---"
        Log "Replace `${mappingType}`: `$(`$oldGuid.Substring(0,8))... -> `$(`$newGuid.Substring(0,8))..."

        `$mappingReplacements = 0

        foreach (`$file in `$allFiles) {
            try {
                `$content = [System.IO.File]::ReadAllText(`$file.FullName)
                `$replaced = [regex]::Replace(`$content, [regex]::Escape(`$oldGuid), `$newGuid, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

                if (`$replaced -ne `$content) {
                    `$relPath = `$file.FullName.Substring(`$reportPath.Length).TrimStart('\','/')
                    # Count replacements
                    `$diff = ([regex]::Matches(`$content, [regex]::Escape(`$oldGuid), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
                    `$mappingReplacements += `$diff

                    # Write replaced content
                    [System.IO.File]::WriteAllText(`$file.FullName, `$replaced)

                    Log "  `${relPath}`: `$diff"
                    if (`$filesChanged -notcontains `$relPath) { `$filesChanged += `$relPath }
                }
            } catch {
                Log "  ERROR processing `$(`$file.Name): `$_"
            }
        }

        Log "  `$mappingType total: `$mappingReplacements"
        `$totalReplacements += `$mappingReplacements
        `$mappingResults += @{
            type = `$mappingType
            oldGuid = `$oldGuid
            newGuid = `$newGuid
            replacements = `$mappingReplacements
        }
    }

    Log "---"
    Log "Total: `$totalReplacements replacement(s)"

    # ============================================================
    # PHASE 3: Verification
    # ============================================================
    SetPhase "verifying"
    Log "=== VERIFY ==="

    `$verificationOk = `$true
    `$oldGuidsRemaining = @{}
    `$newGuidCounts = @{}

    # Re-read file list
    `$allFiles = Get-ChildItem -Path `$reportPath -Recurse -File |
        Where-Object { (`$_.Extension -eq '.tmdl' -or `$_.Extension -eq '.json') -and `$_.FullName -notmatch '\\\.pbi[\\/]' -and `$_.FullName -notmatch '\\cache\.abf`$' -and `$_.DirectoryName -notmatch '\\\.pbi`$' }
    if (-not `$allFiles) { `$allFiles = @() }

    foreach (`$m in `$mappings) {
        `$oldGuid = `$m.OldGuid
        `$newGuid = `$m.NewGuid
        `$mappingType = `$m.Type

        # Check old GUIDs: must be zero
        `$remaining = if (`$allFiles.Count -gt 0) {
            @(Select-String -Path `$allFiles.FullName -Pattern ([regex]::Escape(`$oldGuid)) -CaseSensitive:`$false -List)
        } else { @() }
        if (`$remaining) {
            `$verificationOk = `$false
            Log "FAIL: `$mappingType `$(`$oldGuid.Substring(0,8))... still present:"
            `$oldGuidsRemaining[`$oldGuid] = @()
            foreach (`$r in `$remaining) {
                `$relP = `$r.Path.Substring(`$reportPath.Length).TrimStart('\','/')
                Log "  `${relP}`:`$(`$r.LineNumber): `$(`$r.Line.Trim())"
                `$oldGuidsRemaining[`$oldGuid] += @{ file = `$relP; line = `$r.LineNumber }
            }
        } else {
            Log "OK: `$mappingType `$(`$oldGuid.Substring(0,8))... removed"
        }

        # Check new GUIDs: count should match replacements
        `$newMatches = if (`$allFiles.Count -gt 0) {
            @(Select-String -Path `$allFiles.FullName -Pattern ([regex]::Escape(`$newGuid)) -CaseSensitive:`$false -AllMatches)
        } else { @() }
        `$newCount = 0
        foreach (`$nm in `$newMatches) { `$newCount += `$nm.Matches.Count }
        `$newGuidCounts[`$newGuid] = `$newCount
        Log "  New: `$(`$newGuid.Substring(0,8))... = `$newCount"
    }

    `$applyResults = @{
        filesChanged = `$filesChanged
        totalReplacements = `$totalReplacements
        mappings = `$mappingResults
        verification = @{
            ok = `$verificationOk
            oldGuidsRemaining = `$oldGuidsRemaining
            newGuidCounts = `$newGuidCounts
        }
    }

    Write-ApplyResults `$applyResults

    if (`$verificationOk) {
        Log "=== PASS ==="
        Log "All old GUIDs removed. New GUID counts confirmed."
        Log "Files changed: `$(`$filesChanged.Count)"
        Log "Total replacements: `$totalReplacements"
        Log "DONE: PBIP rebind complete."
        Log "IMPORTANT: Open report in Power BI Desktop to confirm connectivity."
        SetPhase "done"
    } else {
        Log "=== FAILED ==="
        Log "Some old GUIDs remain. Check the log above for details."
        SetPhase "failed"
    }

} catch {
    Log "ERROR during apply: `$_"
    try {
        `$s = Get-Content `$rebindStatusFile -Raw | ConvertFrom-Json
        `$s.error = `$_.Exception.Message
        `$s.phase = "failed"
        `$s.running = `$false
        `$s | ConvertTo-Json -Depth 10 -Compress | Set-Content `$rebindStatusFile
    } catch { }
}
"@
                $rebindWorkerPath = Join-Path $scriptDir "_rebind-worker.ps1"
                [System.IO.File]::WriteAllText($rebindWorkerPath, $rebindWorker, (New-Object System.Text.UTF8Encoding $true))

                if (-not (Test-Path $rebindWorkerPath)) {
                    Set-RebindFailure "Failed to write apply worker"
                    Send-Json $response @{ ok = $false; error = "Failed to write apply worker" }
                    continue
                }

                $errorLog = Join-Path $logsDir "rebind-worker-errors.log"
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "powershell.exe"
                $psi.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$rebindWorkerPath`" 2>`"$errorLog`""
                $psi.CreateNoWindow = $true
                $psi.UseShellExecute = $false
                $proc = [System.Diagnostics.Process]::Start($psi)
                if (-not $proc) {
                    Set-RebindFailure "Failed to start apply worker"
                    Send-Json $response @{ ok = $false; error = "Failed to start apply worker" }
                    continue
                }

                Send-Json $response @{ ok = $true }
            }

            # ============================================================
            # REBIND -- Status
            # ============================================================
            "^/api/rebind/cancel$" {
                if ($method -ne "POST") { $response.StatusCode = 405; continue }
                $state = Get-RebindState
                if ($state -and $state.running) {
                    Send-Json $response @{ ok = $false; error = "A rebind operation is still running" }
                    continue
                }
                if ($state) {
                    $state.phase = "cancelled"
                    $state.running = $false
                    $state.requestSignature = ""
                    $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $rebindStatusFile
                }
                Send-Json $response @{ ok = $true }
            }
            "^/api/rebind/status$" {
                if (Test-Path $rebindStatusFile) {
                    $s = Get-Content $rebindStatusFile -Raw | ConvertFrom-Json
                    Send-Json $response $s
                } else {
                    Send-Json $response @{ phase = "idle"; running = $false; error = ""; logs = @() }
                }
            }

            default {
                $response.StatusCode = 404
            }
        }
    } catch {
        $response.StatusCode = 500
        if ($path -match '^/api/rebind/(scan|apply)$') { Set-RebindFailure $_.Exception.Message }
        try { Send-Json $response @{ ok = $false; error = $_.Exception.Message } } catch { }
    } finally {
        $response.Close()
    }
}
