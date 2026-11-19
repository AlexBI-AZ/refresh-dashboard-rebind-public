# Shared building blocks for the Power BI refresh runner.
#
# Pure helpers only: status mapping, run selection, time stamps, safe error text,
# recipients, webhook lookup, run folders and the run lock. Nothing here calls the
# Power BI service. The runner (refresh-engine.ps1) and the tests dot-source this
# file; it dot-sources powerbi-auth.ps1 from the same folder.
#
# Windows PowerShell 5.1. Keep this file ASCII-only.

. (Join-Path $PSScriptRoot "powerbi-auth.ps1")

function Get-RefreshShortError {
    # Single-line, length-capped error text with anything token-shaped removed.
    param([AllowNull()][object]$Value)

    return Get-PowerBiSafeText $Value
}

function Get-RefreshHttpStatusCode {
    param([AllowNull()][object]$ErrorRecord)

    try { return [int]$ErrorRecord.Exception.Response.StatusCode } catch { return 0 }
}

function ConvertTo-RefreshRecipientList {
    # Splits on commas and semicolons, validates, and removes duplicates
    # case-insensitively. Throws on the first invalid address.
    param([AllowNull()][object[]]$Values)

    $seen = @{}
    $normalized = @()
    foreach ($value in @($Values)) {
        if ($null -eq $value) { continue }
        foreach ($part in ([string]$value -split '[,;]')) {
            $text = $part.Trim()
            if (-not $text) { continue }
            try {
                $address = New-Object System.Net.Mail.MailAddress($text)
                if ($address.Address -ine $text) { throw "Display names are not supported" }
            } catch {
                throw "Invalid email address: $text"
            }
            $key = $address.Address.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $normalized += $address.Address
            }
        }
    }
    return @($normalized)
}

function ConvertTo-RefreshUtcStamp {
    # Normalise a service-returned end time to an explicit UTC string.
    #
    # Dataflow transactions return "...Z", while dataset refresh history returns
    # the same UTC instant with no designator. Parsing with AssumeUniversal makes
    # every value unambiguous, so the email converts all of them the same way.
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return "" }
    if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime().ToString("o") }

    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return [string]$Value
    }
    return $parsed.ToString("o")
}

function ConvertTo-DataflowOutcome {
    # Maps a dataflow transaction status to "Succeeded", "Failed", or "" while it
    # runs. The endpoint returns "Success" or "Failed"; "Failure" is accepted too.
    param([AllowNull()][string]$Status)

    if ($Status -in @("Success", "Succeeded")) { return "Succeeded" }
    if ($Status -in @("Failure", "Failed")) { return "Failed" }
    return ""
}

function ConvertTo-RefreshUtcDate {
    # A service time as a UTC [datetime], or $null when it cannot be read. A value
    # without a zone designator is UTC (dataset refresh history), never local time:
    # a plain [datetime] cast would read it as local and shift it by the UTC offset.
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime() }
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if ([datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $parsed }
    return $null
}

function Select-RefreshCurrentEntry {
    # The newest entry (dataflow transaction or model refresh history row) that
    # started at or after this run's trigger. Older entries belong to a previous
    # run. The 5-second allowance covers clock skew against the service. Returns
    # $null while this run's entry has not appeared yet. Without a trigger time the
    # newest entry is used.
    param([AllowNull()][object[]]$Entries, [AllowNull()][string]$TriggeredAt)

    $notBefore = [datetime]::MinValue
    $trigger = ConvertTo-RefreshUtcDate $TriggeredAt
    if ($null -ne $trigger) { $notBefore = $trigger.AddSeconds(-5) }
    return @(
        @($Entries) |
            Where-Object { $null -ne $_ -and $null -ne (ConvertTo-RefreshUtcDate $_.startTime) -and (ConvertTo-RefreshUtcDate $_.startTime) -ge $notBefore } |
            Sort-Object { ConvertTo-RefreshUtcDate $_.startTime } -Descending |
            Select-Object -First 1
    )[0]
}

function ConvertTo-ModelOutcome {
    # Maps one semantic model refresh state from the service to a status and an
    # error text. Status is "" while the refresh is still running (the service
    # reports that as "Unknown" or "NotStarted").
    param([AllowNull()][object]$State)

    $status = if ($null -eq $State) { "" } else { [string]$State.status }
    switch ($status) {
        "Completed" { return [pscustomobject]@{ Status = "Succeeded"; Error = "" } }
        "Failed" {
            $text = if ($State.serviceExceptionJson) { Get-RefreshShortError $State.serviceExceptionJson } elseif ($State.extendedStatus) { Get-RefreshShortError $State.extendedStatus } else { "Power BI reported a failed refresh." }
            return [pscustomobject]@{ Status = "Failed"; Error = $text }
        }
        "Disabled" { return [pscustomobject]@{ Status = "Failed"; Error = "Refresh is disabled." } }
        "Cancelled" { return [pscustomobject]@{ Status = "Failed"; Error = "Refresh was cancelled." } }
    }
    return [pscustomobject]@{ Status = ""; Error = "" }
}

function Test-TerminalDataflowStatus {
    # "Unknown" is terminal: the status stayed unreadable past the retry budget.
    param([AllowNull()][string]$Status)
    return @("Succeeded", "Failed", "Unknown") -contains $Status
}

function Test-TerminalModelStatus {
    param([AllowNull()][string]$Status)
    return @("Succeeded", "Failed", "Skipped", "Unknown") -contains $Status
}

function Get-RefreshWebhookUrl {
    # Read through the shared reader rather than the raw environment block, so a
    # variable set after the host process started is still seen.
    return (Get-PowerBiConfigValue "REFRESH_EMAIL_WEBHOOK_URL").Value
}

function Resolve-RefreshRunsRoot {
    # Where run folders go: the explicit value, else today's default location.
    param([AllowNull()][string]$RunsRoot)

    if (-not [string]::IsNullOrWhiteSpace($RunsRoot)) { return $RunsRoot }
    return Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "PowerBIChainedRefresh\runs"
}

function New-RefreshRunFolder {
    param([Parameter(Mandatory = $true)][string]$RunsRoot)

    $path = Join-Path $RunsRoot ((Get-Date -Format "yyyyMMdd-HHmmss") + "-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Get-RefreshLockPath {
    # One lock per semantic model, next to the runs folder. The file name is a
    # hash, so no service identifier appears on disk in clear text.
    param(
        [Parameter(Mandatory = $true)][string]$RunsRoot,
        [Parameter(Mandatory = $true)][string]$WorkspaceId,
        [Parameter(Mandatory = $true)][string]$DatasetId
    )

    $text = ($WorkspaceId.Trim() + "|" + $DatasetId.Trim()).ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) } finally { $sha.Dispose() }
    $name = "model-" + (($hash[0..7] | ForEach-Object { $_.ToString("x2") }) -join "") + ".lock"
    return Join-Path (Join-Path (Split-Path -Parent $RunsRoot) "locks") $name
}

function Enter-RefreshRunLock {
    # Creates the lock atomically. A lock whose owner process no longer exists on
    # this computer is stale and is replaced; a live one makes this throw.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$RunFolder = "",
        [string]$Label = "this semantic model"
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $self = Get-Process -Id $PID
    $payload = [ordered]@{
        pid = $PID
        processStart = $self.StartTime.ToString("o")
        computer = $env:COMPUTERNAME
        runFolder = $RunFolder
        acquiredAt = (Get-Date).ToString("o")
    } | ConvertTo-Json
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($payload)

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Close() }
            return
        } catch [System.IO.IOException] {
            $holder = $null
            try { $holder = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { }
            $alive = $true
            if ($null -ne $holder -and [string]$holder.computer -ieq $env:COMPUTERNAME) {
                $process = Get-Process -Id ([int]$holder.pid) -ErrorAction SilentlyContinue
                $alive = $null -ne $process -and $process.StartTime.ToString("o") -eq [string]$holder.processStart
            } elseif ($null -eq $holder) {
                $alive = $false
            }
            if ($alive) {
                throw "A refresh run for $Label is already active (process $($holder.pid) on $($holder.computer), run folder $($holder.runFolder)). Nothing was started."
            }
            Remove-Item -LiteralPath $Path -Force
        }
    }
    throw "The run lock could not be acquired: $Path"
}

function Exit-RefreshRunLock {
    # Removes the lock only when this process owns it.
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $holder = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ([int]$holder.pid -eq $PID) { Remove-Item -LiteralPath $Path -Force }
    } catch { }
}

function Write-RefreshJsonFile {
    # UTF-8 without a byte order mark, so any JSON reader can consume it.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [switch]$Compress
    )

    $json = if ($Compress) { $Value | ConvertTo-Json -Depth 10 -Compress } else { $Value | ConvertTo-Json -Depth 10 }
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}
