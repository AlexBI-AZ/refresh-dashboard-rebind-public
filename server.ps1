param(
    [int]$Port = 8765,
    [switch]$NoBrowser,
    [switch]$AppWindow
)

$ErrorActionPreference = "SilentlyContinue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$profilesFile = Join-Path $scriptDir "profiles.json"
$htmlFile = Join-Path $scriptDir "index.html"
$statusFile = Join-Path $scriptDir "refresh-status.json"
$workerFile = Join-Path $scriptDir "refresh-worker.json"
$rebindStatusFile = Join-Path $scriptDir "rebind-status.json"
$rebindProfilesFile = Join-Path $scriptDir "rebind-profiles.json"
$partitionRefreshProfilesFile = Join-Path $scriptDir "partition-refresh-profiles.json"
$partitionRefreshStatusFile = Join-Path $scriptDir "partition-refresh-status.json"
$logsDir = Join-Path $scriptDir "logs"
. (Join-Path $scriptDir "partition-refresh.ps1")
$global:partitionSubmissionInProgress = $false

# Ensure logs directory exists
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

# ============================================================
# Optional authentication (Refresh only)
# ============================================================
$global:msalAvailable = $false
# Started from a PowerShell 7 shell (for example through Start-Process or a .bat file),
# Windows PowerShell inherits PowerShell 7's PSModulePath. That path misses the Windows
# PowerShell user module folder, where MSAL.PS is usually installed, and lists PowerShell 7's
# own copies of built-in modules, which break MSAL.PS's import. Rebuild it with the Windows
# PowerShell folders first and the PowerShell 7 folders removed; worker processes inherit it.
if ($PSVersionTable.PSEdition -ne 'Core') {
    $windowsPowerShellModuleDirs = @(
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'),
        (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
        (Join-Path $PSHOME 'Modules')
    )
    $otherModuleDirs = @($env:PSModulePath -split ';' | Where-Object {
        $_ -and
        ($windowsPowerShellModuleDirs -notcontains $_.TrimEnd('\')) -and
        $_ -notmatch '\\PowerShell\\(Modules|7)' -and
        $_ -notmatch '\\Microsoft\.PowerShell_[^\\]+\\Modules'
    })
    $env:PSModulePath = (@($windowsPowerShellModuleDirs) + $otherModuleDirs) -join ';'
}
try {
    Import-Module MSAL.PS -Force -ErrorAction Stop
    $global:msalAvailable = $true
} catch {
    Write-Host "MSAL.PS is not installed. Rebind is ready; Refresh authentication is unavailable." -ForegroundColor Yellow
    Write-Host "For Refresh, install with: Install-Module -Name MSAL.PS -Scope CurrentUser -Force" -ForegroundColor Gray
}
# All Power BI sign-in goes through runtime\powerbi-auth.ps1, the same module the refresh
# worker renews its token with: the certificate (service principal) when it is configured,
# otherwise a device-code sign-in kept in that module's encrypted cache. One run therefore
# never switches identity between start and renewal.
. (Join-Path $scriptDir "runtime\powerbi-auth.ps1")
# Read-only lookups behind the Refresh tab's name pickers (workspaces, reports, semantic
# models, dataflows, lineage). Same engine as the runner; see Invoke-CatalogRequest.
. (Join-Path $scriptDir "runtime\refresh-catalog.ps1")
# Rebind: request and profile validation, the operation lock, Scan/Apply workers and
# their status. Each Scan or Apply runs runtime\Invoke-RebindRun.ps1 in its own process.
. (Join-Path $scriptDir "runtime\rebind-core.ps1")
$rebindPaths = @{
    StatusFile = $rebindStatusFile
    LockFile = Join-Path $scriptDir "rebind.lock"
    RunnerPath = Join-Path $scriptDir "runtime\Invoke-RebindRun.ps1"
    ErrorLogPath = Join-Path $logsDir "rebind-worker-errors.log"
}
$global:catalogWorkspaceCache = $null
$global:cachedToken = $null
$global:cachedTokenAt = $null
$global:authContext = $null
$global:authMode = ""
$tokenRenewalAge = [TimeSpan]::FromMinutes(40)

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Power BI Dashboard Control Panel" -ForegroundColor Cyan
Write-Host "  by Alex Paraschakis" -ForegroundColor Gray
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Rebind starts without authentication. Authenticate from the Refresh tab only if needed." -ForegroundColor Green
Write-Host ""

# ============================================================
# Helpers
# ============================================================
function Get-Token {
    param([switch]$Interactive)

    if (-not $global:msalAvailable) { throw "MSAL.PS not installed" }
    if ($global:cachedToken -and $global:cachedTokenAt -and ((Get-Date) - $global:cachedTokenAt) -lt $tokenRenewalAge) {
        return $global:cachedToken
    }
    $global:cachedToken = $null

    if (-not $global:authContext) {
        $global:authContext = New-PowerBiAuthContext
        $global:authMode = $global:authContext.Mode
    }

    try {
        $global:cachedToken = Get-PowerBiAccessToken -Context $global:authContext
    } catch {
        # Only device-code sign-in can ask a person; a certificate error is final.
        if ($global:authContext.Mode -ne "delegated" -or -not $Interactive) {
            if ($global:authContext.Mode -eq "delegated") { throw "Not authenticated" }
            throw
        }
        Write-Host ""
        Write-Host "Device-code sign-in for Refresh (this PC does not use a certificate)." -ForegroundColor Yellow
        Write-Host "Use the device URL and code shown below. Rebind itself never requires this step." -ForegroundColor Yellow
        if ($AppWindow) { Show-ServerConsole }
        $result = Get-MsalToken -PublicClientApplication $global:authContext.Client -Scopes $global:authContext.Scopes -DeviceCode -Timeout (New-TimeSpan -Minutes 10) -ErrorAction Stop
        $global:cachedToken = [string]$result.AccessToken
        Write-Host "Authenticated. Refresh is ready." -ForegroundColor Green
    }

    if ([string]::IsNullOrWhiteSpace($global:cachedToken)) { $global:cachedToken = $null; throw "Not authenticated" }
    $global:cachedTokenAt = Get-Date
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

function Invoke-CatalogRequest {
    # The read-only catalog endpoints. Returns @{ Status; Body } so the route only sends
    # it. Every lookup is a GET against Power BI; nothing is started or changed.
    #   GET  /api/catalog/workspaces[?refresh=1]          workspaces (cached 5 minutes)
    #   GET  /api/catalog/items?workspaceId=<guid>        reports, semantic models, dataflows
    #   GET  /api/catalog/upstream?workspaceId=&datasetId= a model and its upstream dataflows
    #   POST /api/catalog/names {workspaceIds, dataflows, semanticModels}  names for saved IDs
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Method,
        [AllowNull()][object]$Query,
        [AllowNull()][object]$Body,
        [Parameter(Mandatory = $true)][string]$Token
    )

    $reply = { param([int]$Status, [hashtable]$Content) @{ Status = $Status; Body = $Content } }
    $routes = @{
        "/api/catalog/workspaces" = "GET"
        "/api/catalog/items" = "GET"
        "/api/catalog/upstream" = "GET"
        "/api/catalog/names" = "POST"
    }
    if (-not $routes.ContainsKey($Path)) { return & $reply 404 @{ ok = $false; error = "Unknown catalog request" } }
    if ($Method -ne $routes[$Path]) { return & $reply 405 @{ ok = $false; error = "Method not allowed" } }
    $workspaceId = if ($null -ne $Query) { ([string]$Query["workspaceId"]).Trim() } else { "" }
    $datasetId = if ($null -ne $Query) { ([string]$Query["datasetId"]).Trim() } else { "" }
    if ($Path -in @("/api/catalog/items", "/api/catalog/upstream") -and -not (Test-RefreshCatalogGuid $workspaceId)) {
        return & $reply 400 @{ ok = $false; error = "workspaceId must be a valid GUID" }
    }
    if ($Path -eq "/api/catalog/upstream" -and -not (Test-RefreshCatalogGuid $datasetId)) {
        return & $reply 400 @{ ok = $false; error = "datasetId must be a valid GUID" }
    }

    try {
        Initialize-RefreshCatalog -Token $Token
        switch ($Path) {
            "/api/catalog/workspaces" {
                $refresh = $null -ne $Query -and [string]$Query["refresh"] -eq "1"
                $cache = $global:catalogWorkspaceCache
                if ($refresh -or $null -eq $cache -or ((Get-Date) - $cache.At) -gt [TimeSpan]::FromMinutes(5)) {
                    $cache = @{ At = Get-Date; Items = @(Get-RefreshCatalogWorkspaces) }
                    $global:catalogWorkspaceCache = $cache
                }
                return & $reply 200 @{ ok = $true; workspaces = @($cache.Items); loadedAt = $cache.At.ToString("o") }
            }
            "/api/catalog/items" {
                $items = Get-RefreshCatalogWorkspaceItems -WorkspaceId $workspaceId
                return & $reply 200 @{ ok = $true; reports = @($items.reports); semanticModels = @($items.semanticModels); dataflows = @($items.dataflows); warnings = @($items.warnings) }
            }
            "/api/catalog/upstream" {
                $upstream = Get-RefreshCatalogUpstream -WorkspaceId $workspaceId -DatasetId $datasetId
                return & $reply 200 @{ ok = $true; model = $upstream.model; dataflows = @($upstream.dataflows); warnings = @($upstream.warnings) }
            }
            "/api/catalog/names" {
                $names = Resolve-RefreshCatalogNames -WorkspaceIds @($Body.workspaceIds) -Dataflows @($Body.dataflows) -SemanticModels @($Body.semanticModels)
                return & $reply 200 @{ ok = $true; workspaces = @($names.workspaces); dataflows = @($names.dataflows); semanticModels = @($names.semanticModels) }
            }
        }
    } catch {
        if (Test-RefreshAuthorizationError $_) { return & $reply 401 @{ ok = $false; error = "Power BI rejected the sign-in. Sign in again." } }
        return & $reply 502 @{ ok = $false; error = "Power BI lookup failed: $(Get-RefreshShortError $_)" }
    }
}

function Get-RefreshRequest {
    param($Body)

    # The dataflow workspace is needed only when dataflows are listed: a model-only run
    # (the Refresh tab's "Model only" box) sends none, and each semantic model carries
    # its own workspace. A workspace that is given must still be a valid GUID.
    $workspaceId = ([string]$Body.WorkspaceId).Trim()
    $workspaceGuid = [Guid]::Empty
    $workspaceValid = [Guid]::TryParse($workspaceId, [ref]$workspaceGuid)
    if (-not $workspaceValid -and $workspaceId) {
        return [pscustomobject]@{ Ok = $false; Error = "Workspace ID must be a valid GUID" }
    }
    if ($workspaceValid) { $workspaceId = $workspaceGuid.ToString() }

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
    if ($dataflows.Count -gt 0 -and -not $workspaceValid) {
        return [pscustomobject]@{ Ok = $false; Error = "Workspace ID must be a valid GUID when dataflows are listed" }
    }

    # Dataflows chosen by name can live in different workspaces, so they may also come as
    # Dataflows = [{WorkspaceId, DataflowId}]; an entry without a workspace uses the
    # request's. They travel to the runner as they are (Resolve-RefreshPlanByIds).
    $dataflowEntries = @()
    foreach ($rawEntry in @(@($Body.Dataflows) | Where-Object { $null -ne $_ })) {
        $entryWorkspaceId = if ($rawEntry.WorkspaceId) { ([string]$rawEntry.WorkspaceId).Trim() } else { $workspaceId }
        $entryWorkspaceGuid = [Guid]::Empty
        $entryDataflowGuid = [Guid]::Empty
        if (-not [Guid]::TryParse($entryWorkspaceId, [ref]$entryWorkspaceGuid) -or -not [Guid]::TryParse(([string]$rawEntry.DataflowId).Trim(), [ref]$entryDataflowGuid)) {
            return [pscustomobject]@{ Ok = $false; Error = "Every dataflow must have valid workspace and dataflow GUIDs" }
        }
        $key = ($entryWorkspaceGuid.ToString() + "|" + $entryDataflowGuid.ToString()).ToLowerInvariant()
        $legacyKey = $entryDataflowGuid.ToString().ToLowerInvariant()
        if ($seenDataflows.ContainsKey($key) -or ($entryWorkspaceGuid.ToString() -eq $workspaceId -and $seenDataflows.ContainsKey($legacyKey))) { continue }
        $seenDataflows[$key] = $true
        $dataflowEntries += [pscustomobject][ordered]@{ WorkspaceId = $entryWorkspaceGuid.ToString(); DataflowId = $entryDataflowGuid.ToString() }
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
        WorkspaceId = $workspaceId
        DataflowIds = @($dataflows)
        Dataflows = @($dataflowEntries)
        SemanticModels = @($models)
        NotificationRecipients = @($normalizedRecipients.Recipients)
        EmailDryRun = ($Body.EmailDryRun -eq $true)
    }
}

function ConvertTo-RefreshProcessArgument {
    param([string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function New-RefreshRunnerStartInfo {
    # Process start settings for runtime\Invoke-RefreshRun.ps1, the refresh runner the
    # Claude skill uses too. The plan travels as base64 JSON; the token and its sign-in
    # mode travel only in the child's environment, never in its arguments or a file.
    # The child inherits this server's PSModulePath, so it finds MSAL.PS the same way.
    param(
        [Parameter(Mandatory = $true)][object]$RefreshRequest,
        [Parameter(Mandatory = $true)][string]$RunnerPath,
        [Parameter(Mandatory = $true)][string]$StatusFile,
        [Parameter(Mandatory = $true)][string]$ErrorLogPath,
        [AllowNull()][string]$Token,
        [AllowNull()][string]$AuthMode
    )

    $planObject = [ordered]@{
        WorkspaceId = [string]$RefreshRequest.WorkspaceId
        DataflowIds = @($RefreshRequest.DataflowIds)
        SemanticModels = @($RefreshRequest.SemanticModels)
    }
    # Dataflows with their own workspace go only when there are any, so a plan in the
    # original form stays byte-for-byte what it was.
    if (@($RefreshRequest.Dataflows).Count -gt 0) { $planObject.Dataflows = @($RefreshRequest.Dataflows) }
    $plan = $planObject | ConvertTo-Json -Depth 10 -Compress
    $planBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($plan))

    $arguments = @(
        "-NoProfile"
        "-ExecutionPolicy Bypass"
        "-WindowStyle Hidden"
        "-File $(ConvertTo-RefreshProcessArgument $RunnerPath)"
        "-PlanBase64 $planBase64"
        "-StatusFile $(ConvertTo-RefreshProcessArgument $StatusFile)"
        "-ErrorLogPath $(ConvertTo-RefreshProcessArgument $ErrorLogPath)"
        "-Confirmed"
    )
    # powershell.exe -File binds a list parameter only once, so recipients go as one value.
    $recipientList = @($RefreshRequest.NotificationRecipients | Where-Object { $_ }) -join ","
    if ($recipientList) { $arguments += "-Recipients $(ConvertTo-RefreshProcessArgument $recipientList)" }
    if ($RefreshRequest.EmailDryRun -eq $true) { $arguments += "-PreviewEmail" }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = $arguments -join " "
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $psi.EnvironmentVariables["POWERBI_REFRESH_INITIAL_TOKEN"] = $Token
        $psi.EnvironmentVariables["POWERBI_REFRESH_INITIAL_TOKEN_MODE"] = [string]$AuthMode
    }
    return $psi
}

function Test-RefreshWorkerAlive {
    # True while the runner process recorded in the worker file still runs. A missing
    # or unreadable record counts as alive, so a refresh started before the record
    # existed is never declared dead; a recorded process that is gone (or whose start
    # time differs, because Windows reused its ID) means the worker died.
    param([string]$WorkerFile)

    if (-not (Test-Path -LiteralPath $WorkerFile)) { return $true }
    try { $worker = Get-Content -LiteralPath $WorkerFile -Raw | ConvertFrom-Json } catch { return $true }
    if ($null -eq $worker -or -not $worker.pid) { return $true }
    $process = Get-Process -Id ([int]$worker.pid) -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    try { return $process.StartTime.ToString("o") -eq [string]$worker.startTime } catch { return $true }
}

# ============================================================
# App window (Edge --app mode)
# ============================================================
function Show-ServerConsole {
    # The device-code prompt is printed here, so a minimized console is brought back for sign-in.
    try {
        if (-not ('ControlPanel.ConsoleWindow' -as [type])) {
            Add-Type -Namespace ControlPanel -Name ConsoleWindow -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
'@
        }
        $handle = [ControlPanel.ConsoleWindow]::GetConsoleWindow()
        if ($handle -ne [IntPtr]::Zero) {
            [ControlPanel.ConsoleWindow]::ShowWindow($handle, 9) | Out-Null
            [ControlPanel.ConsoleWindow]::SetForegroundWindow($handle) | Out-Null
        }
    } catch { }
}

function Find-EdgePath {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe"),
        (Join-Path $env:ProgramFiles "Microsoft\Edge\Application\msedge.exe"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\Edge\Application\msedge.exe")
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    try {
        $appPath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe" -ErrorAction Stop).'(default)'
        if ($appPath -and (Test-Path -LiteralPath $appPath)) { return $appPath }
    } catch { }
    return $null
}

function Start-AppWindow([string]$Url) {
    # A dedicated Edge profile makes the started process own this window only,
    # so its exit means the user closed the app.
    $edgePath = Find-EdgePath
    if (-not $edgePath) {
        Write-Host "Microsoft Edge was not found. Opening the default browser instead." -ForegroundColor Yellow
        Start-Process $Url
        return $null
    }
    $profileDir = Join-Path $env:LOCALAPPDATA "PowerBIControlPanel\EdgeAppProfile"
    if (-not (Test-Path -LiteralPath $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
    $edgeArgs = @(
        "--app=$Url",
        "--user-data-dir=`"$profileDir`"",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-features=msImplicitSignin",
        "--window-size=1400,900"
    )
    return Start-Process -FilePath $edgePath -ArgumentList $edgeArgs -PassThru
}

# ============================================================
# Start HTTP listener
# ============================================================
$appUrl = "http://localhost:$Port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($appUrl)
$listener.Start()

if (-not $listener.IsListening) {
    if ($AppWindow) {
        # Most likely the Control Panel is already running: open a window onto it and leave.
        Write-Host "Port $Port is in use. Opening a window onto the running Control Panel." -ForegroundColor Yellow
        Start-AppWindow $appUrl | Out-Null
        exit 0
    }
    Write-Host "Could not listen on port $Port. Is the Control Panel already running?" -ForegroundColor Red
    exit 1
}

Write-Host "Dashboard running at: http://localhost:$Port" -ForegroundColor Yellow
if ($AppWindow) {
    Write-Host "Closing the app window stops the server." -ForegroundColor Gray
} else {
    Write-Host "Do not close this window - it is the server." -ForegroundColor Gray
}
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

$appProcess = $null
if ($AppWindow) {
    $appProcess = Start-AppWindow $appUrl
} elseif (-not $NoBrowser) {
    Start-Process "http://localhost:$Port"
}

# Clear stale status files
@{ running = $false; result = ""; logs = @(); dataflowStatus = ""; datasetStatus = ""; dataflowDetails = @(); semanticModelDetails = @(); emailStatus = ""; emailWarning = ""; error = "" } | ConvertTo-Json -Depth 10 | Set-Content $statusFile
# Rebind status is reconciled, not reset: a worker that still runs keeps its lock and status.
try {
    $rebindStartup = Initialize-RebindStatus -Paths $rebindPaths
    if ($rebindStartup -eq "WorkerActive") { Write-Host "A Rebind operation is still running; its status was kept." -ForegroundColor Yellow }
    elseif ($rebindStartup -eq "Interrupted") { Write-Host "The previous Rebind operation stopped before finishing; it is marked as interrupted." -ForegroundColor Yellow }
} catch {
    Write-Host "Rebind status could not be checked: $(Get-RebindSafeText $_.Exception.Message)" -ForegroundColor Yellow
}
if (-not (Test-Path -LiteralPath $partitionRefreshStatusFile)) {
    @{ running = $false; requestId = ""; status = ""; extendedStatus = ""; logs = @(); partitions = @() } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $partitionRefreshStatusFile
}

while ($listener.IsListening) {
    # Wait in short slices so a closed app window is noticed between requests.
    $contextTask = $listener.GetContextAsync()
    while (-not $contextTask.Wait(500)) {
        if ($appProcess -and $appProcess.HasExited) { break }
    }
    if (-not $contextTask.IsCompleted) {
        Write-Host "App window closed. Stopping the server." -ForegroundColor Yellow
        $listener.Stop()
        break
    }
    $context = $contextTask.Result
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
            "^/api/catalog/" {
                # Read-only name lookups for the pickers; see Invoke-CatalogRequest.
                try { $catalogToken = Get-Token } catch {
                    $response.StatusCode = 401
                    Send-Json $response @{ ok = $false; error = "Sign in first to look up names." }
                    continue
                }
                $catalogBody = $null
                if ($method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream)
                    try { $catalogBody = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop } catch { $catalogBody = $null }
                    $reader.Close()
                    if ($null -eq $catalogBody) {
                        $response.StatusCode = 400
                        Send-Json $response @{ ok = $false; error = "Invalid catalog request JSON" }
                        continue
                    }
                }
                $catalogResult = Invoke-CatalogRequest -Path $path -Method $method -Query $request.QueryString -Body $catalogBody -Token $catalogToken
                $catalogToken = $null
                $response.StatusCode = $catalogResult.Status
                Send-Json $response $catalogResult.Body
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
                    authMode = $global:authMode
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
                if ($current -and $current.running -and (Test-RefreshWorkerAlive $workerFile)) {
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

                # The refresh itself runs in runtime\Invoke-RefreshRun.ps1, the runner the
                # Claude skill uses too. The old _worker.ps1, generated from
                # _refresh-worker-template.ps1 with the token written into it, is no
                # longer used; an old copy is removed because it may still hold a token.
                $runnerPath = Join-Path $scriptDir "runtime\Invoke-RefreshRun.ps1"
                $emailModulePath = Join-Path $scriptDir "refresh-email.ps1"
                if (-not (Test-Path $runnerPath) -or -not (Test-Path $emailModulePath)) {
                    Send-Json $response @{ ok = $false; error = "Refresh runner or email module was not found" }
                    continue
                }
                Remove-Item -LiteralPath (Join-Path $scriptDir "_worker.ps1") -Force -ErrorAction SilentlyContinue

                [ordered]@{
                    running = $true; result = "Starting"; startTime = (Get-Date -Format "o"); endTime = ""; durationSeconds = 0
                    logs = @(); dataflowStatus = "Pending"; datasetStatus = "Pending"; dataflowDetails = @(); semanticModelDetails = @()
                    emailStatus = if ($refreshRequest.NotificationRecipients.Count -gt 0) { "Pending" } else { "Skipped" }
                    emailWarning = ""; error = ""
                } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statusFile

                $errorLog = Join-Path $logsDir "refresh-worker-errors.log"
                $psi = New-RefreshRunnerStartInfo -RefreshRequest $refreshRequest -RunnerPath $runnerPath -StatusFile $statusFile -ErrorLogPath $errorLog -Token $tokenForWorker -AuthMode $global:authMode
                $proc = $null
                try { $proc = [System.Diagnostics.Process]::Start($psi) } catch { $proc = $null }
                $psi = $null
                if (-not $proc) {
                    @{ running = $false; result = "Failed"; logs = @(); dataflowStatus = ""; datasetStatus = ""; dataflowDetails = @(); semanticModelDetails = @(); emailStatus = ""; emailWarning = ""; error = "Failed to start worker process" } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statusFile
                    Send-Json $response @{ ok = $false; error = "Failed to start worker process" }
                    continue
                }
                # Which process runs this refresh, so a worker that dies does not leave the
                # tab stuck on "already running".
                $workerStart = ""
                try { $workerStart = $proc.StartTime.ToString("o") } catch { }
                [ordered]@{ pid = $proc.Id; startTime = $workerStart } | ConvertTo-Json | Set-Content -LiteralPath $workerFile

                Send-Json $response @{ ok = $true }
            }
            "^/api/refresh/status$" {
                if ($method -ne "GET") { $response.StatusCode = 405; continue }
                if (Test-Path $statusFile) {
                    $s = Get-Content $statusFile -Raw | ConvertFrom-Json
                    # A worker that died cannot clear "running" itself. Report it as not
                    # running, so the Refresh tab shows "Worker died" and points to the log.
                    if ($s -and $s.running -and -not (Test-RefreshWorkerAlive $workerFile)) { $s.running = $false }
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

                $existing = if (Test-Path -LiteralPath $partitionRefreshStatusFile) { try { Get-Content -LiteralPath $partitionRefreshStatusFile -Raw | ConvertFrom-Json } catch { $null } } else { $null }
                if ($existing -and $existing.running) {
                    try {
                        $historyUri = "https://api.powerbi.com/v1.0/myorg/groups/$($existing.workspaceId)/datasets/$($existing.datasetId)/refreshes?`$top=60"
                        $history = Invoke-RestMethod -Method GET -Uri $historyUri -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop
                        if (Update-PartitionRefreshStateFromHistory $existing $history) {
                            $existing.running = $false
                            $existing | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $partitionRefreshStatusFile -Encoding UTF8
                        }
                    } catch { }
                    if ($existing.running) {
                        $response.StatusCode = 409; Send-Json $response @{ ok = $false; error = "The current partition refresh is still in progress. Check its status before starting another request." }; continue
                    }
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
                $headers = @{ Authorization = "Bearer $token" }
                $detailsError = ""
                try {
                    $uri = "https://api.powerbi.com/v1.0/myorg/groups/$($state.workspaceId)/datasets/$($state.datasetId)/refreshes/$($state.requestId)"
                    $remote = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
                    foreach ($property in @("status", "extendedStatus", "startTime", "endTime", "attempts", "objects", "messages")) {
                        if ($null -ne $remote.$property) { $state.$property = $remote.$property }
                    }
                } catch {
                    $detailsError = $_.Exception.Message
                }
                if (-not (Test-PartitionRefreshTerminalStatus $state)) {
                    try {
                        $historyUri = "https://api.powerbi.com/v1.0/myorg/groups/$($state.workspaceId)/datasets/$($state.datasetId)/refreshes?`$top=60"
                        $history = Invoke-RestMethod -Method GET -Uri $historyUri -Headers $headers -ErrorAction Stop
                        [void](Update-PartitionRefreshStateFromHistory $state $history)
                    } catch { }
                }
                $state.running = -not (Test-PartitionRefreshTerminalStatus $state)
                $state | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $partitionRefreshStatusFile -Encoding UTF8
                if ($detailsError -and $state.running) {
                    $response.StatusCode = 502; Send-Json $response @{ ok = $false; error = "Could not retrieve partition refresh status: $detailsError"; state = $state }
                } else { Send-Json $response $state }
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
                    $saved = Read-RebindProfileFile -Path $rebindProfilesFile
                    if (-not $saved.Ok) {
                        $response.StatusCode = 500
                        Send-Json $response @{ ok = $false; error = $saved.Error }
                        continue
                    }
                    $buf = [System.Text.Encoding]::UTF8.GetBytes($saved.Json)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $buf.Length
                    $response.OutputStream.Write($buf, 0, $buf.Length)
                } elseif ($method -eq "POST") {
                    # The whole collection is validated before the saved file is replaced.
                    $bodyText = Read-RebindRequestText -Stream $request.InputStream -DeclaredLength $request.ContentLength64
                    if (-not $bodyText.Ok) {
                        $response.StatusCode = $bodyText.StatusCode
                        Send-Json $response @{ ok = $false; error = $bodyText.Error }
                        continue
                    }
                    $saveResult = Save-RebindProfileFile -Path $rebindProfilesFile -Json $bodyText.Text
                    $response.StatusCode = $saveResult.StatusCode
                    Send-Json $response $saveResult.Body
                } else {
                    $response.StatusCode = 405
                    Send-Json $response @{ ok = $false; error = "Method not allowed" }
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
            # REBIND -- Scan (Phase 1) and Apply (Phase 2 + 3)
            # ============================================================
            # A malformed or refused request returns an error and leaves the status of
            # any running operation alone; only the worker that owns the lock writes it.
            "^/api/rebind/(scan|apply)$" {
                if ($method -ne "POST") { $response.StatusCode = 405; Send-Json $response @{ ok = $false; error = "Method not allowed" }; continue }
                $bodyText = Read-RebindRequestText -Stream $request.InputStream -DeclaredLength $request.ContentLength64
                if (-not $bodyText.Ok) {
                    $response.StatusCode = $bodyText.StatusCode
                    Send-Json $response @{ ok = $false; error = $bodyText.Error }
                    continue
                }
                $parsed = ConvertFrom-RebindRequestJson -Text $bodyText.Text
                if (-not $parsed.Ok) {
                    $response.StatusCode = 400
                    Send-Json $response @{ ok = $false; error = $parsed.Error }
                    continue
                }
                $rebindMode = if ($path -eq "/api/rebind/apply") { "Apply" } else { "Scan" }
                $startResult = Start-RebindOperation -Mode $rebindMode -Body $parsed.Value -Paths $rebindPaths
                $response.StatusCode = $startResult.StatusCode
                Send-Json $response $startResult.Body
            }

            # ============================================================
            # REBIND -- Cancel and status
            # ============================================================
            "^/api/rebind/cancel$" {
                if ($method -ne "POST") { $response.StatusCode = 405; Send-Json $response @{ ok = $false; error = "Method not allowed" }; continue }
                $bodyText = Read-RebindRequestText -Stream $request.InputStream -DeclaredLength $request.ContentLength64
                $parsed = if ($bodyText.Ok) { ConvertFrom-RebindRequestJson -Text $bodyText.Text -AllowEmpty } else { $null }
                if (-not $bodyText.Ok -or -not $parsed.Ok) {
                    $response.StatusCode = $(if (-not $bodyText.Ok) { $bodyText.StatusCode } else { 400 })
                    Send-Json $response @{ ok = $false; invalidated = $false; error = $(if (-not $bodyText.Ok) { $bodyText.Error } else { $parsed.Error }) }
                    continue
                }
                $cancelOperationId = if ($parsed.Value) { [string]$parsed.Value.OperationId } else { "" }
                $cancelResult = Invoke-RebindCancel -Paths $rebindPaths -OperationId $cancelOperationId
                $response.StatusCode = $cancelResult.StatusCode
                Send-Json $response $cancelResult.Body
            }
            "^/api/rebind/status$" {
                if ($method -ne "GET") { $response.StatusCode = 405; Send-Json $response @{ ok = $false; error = "Method not allowed" }; continue }
                $statusResult = Get-RebindStatusResponse -Paths $rebindPaths
                $response.StatusCode = $statusResult.StatusCode
                Send-Json $response $statusResult.Body
            }

            default {
                $response.StatusCode = 404
            }
        }
    } catch {
        # Never touches Rebind status: only the operation that holds rebind.lock writes it.
        $response.StatusCode = 500
        try { Send-Json $response @{ ok = $false; error = $_.Exception.Message } } catch { }
    } finally {
        $response.Close()
    }
}
