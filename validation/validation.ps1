# Validation helpers for a validated Power BI refresh. Report-neutral: the
# workspace, report and checks come from a config in the reports folder.
# Dot-source this file. It defines functions and has no side effects.
# All text is ASCII so Windows PowerShell 5.1 reads it correctly.

function Resolve-ValidationConfigPath {
    # -ConfigPath wins. Otherwise -Report <name> selects reports\<name>.config.json.
    # With neither, the only config in the reports folder is used; when there are
    # several, the caller must choose.
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [string]$ConfigPath,
        [string]$Report
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config not found: $ConfigPath" }
        return (Resolve-Path -LiteralPath $ConfigPath).Path
    }
    $folder = Join-Path $ToolRoot "reports"
    $suffix = ".config.json"
    $available = @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue | Where-Object { $_.Name.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object Name)
    $names = @($available | ForEach-Object { $_.Name.Substring(0, $_.Name.Length - $suffix.Length) })
    $namesText = if ($names.Count -gt 0) { $names -join ", " } else { "none" }
    if (-not [string]::IsNullOrWhiteSpace($Report)) {
        $match = @($available | Where-Object { $_.Name -ieq ($Report.Trim() + $suffix) }) | Select-Object -First 1
        if ($null -eq $match) { throw "No config for report '$Report' in $folder. Available: $namesText" }
        return $match.FullName
    }
    if ($available.Count -eq 1) { return $available[0].FullName }
    if ($available.Count -eq 0) { throw "No report configs (*$suffix) found in $folder." }
    throw "Several report configs exist in $folder; pass -Report. Available: $namesText"
}

function Read-ValidationConfig {
    # Reads a config as UTF-8. Get-Content in Windows PowerShell 5.1 would decode a
    # file without BOM in the ANSI code page and garble non-ASCII text such as the
    # Russian emailNote.
    param([Parameter(Mandatory = $true)][string]$Path)
    return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
}

function Get-ValidationConfigValue {
    param([string]$Name, [string]$Default = "")
    foreach ($scope in @("Process", "User", "Machine")) {
        $value = [Environment]::GetEnvironmentVariable($Name, $scope)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    return $Default
}

function ConvertTo-ValidationNumber {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or
        $Value -is [decimal] -or $Value -is [single] -or $Value -is [int16] -or
        $Value -is [int64] -or $Value -is [byte]) {
        return [double]$Value
    }

    $text = ([string]$Value).Trim()
    if (-not $text) { return $null }
    # Spaces (including non-breaking ones) are group separators in ru-RU output.
    $text = $text -replace ('[\s' + [char]0x00A0 + ']'), ''

    # Decide what a comma means before parsing. Parsing with AllowThousands first
    # silently turns "523344,82" into 52334482, so thousands are never assumed.
    if ($text.Contains(',') -and $text.Contains('.')) {
        if ($text.LastIndexOf('.') -gt $text.LastIndexOf(',')) {
            $text = $text.Replace(',', '')
        } else {
            $text = $text.Replace('.', '').Replace(',', '.')
        }
    } elseif ($text -match '^[+-]?\d{1,3}(,\d{3}){2,}$') {
        $text = $text.Replace(',', '')
    } elseif ($text.Contains(',')) {
        $text = $text.Replace(',', '.')
    }

    $parsed = 0.0
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-ValidationSafeText {
    # Single-line, length-capped error text with anything token-shaped removed.
    param([AllowNull()][object]$Value)

    $text = if ($Value -is [System.Management.Automation.ErrorRecord]) { [string]$Value.Exception.Message } else { [string]$Value }
    $text = ($text -replace '[\r\n]+', ' ').Trim()
    $text = $text -replace '(?i)bearer\s+[A-Za-z0-9\-\._~\+/]+=*', 'Bearer [removed]'
    $text = $text -replace 'eyJ[A-Za-z0-9\-_]{10,}\.[A-Za-z0-9\-_]{10,}\.[A-Za-z0-9\-_]*', '[token removed]'
    $text = $text -replace '(?i)([?&]sig=)[^&\s]+', '$1[removed]'
    if ($text.Length -gt 500) { $text = $text.Substring(0, 500) + "..." }
    return $text
}

function ConvertTo-ValidationDate {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return [datetime]$Value }

    $text = ([string]$Value).Trim()
    if (-not $text) { return $null }
    $parsed = [datetime]::MinValue
    foreach ($culture in @([System.Globalization.CultureInfo]::InvariantCulture,
                           [System.Globalization.CultureInfo]::CurrentCulture,
                           [System.Globalization.CultureInfo]::GetCultureInfo('ru-RU'))) {
        if ([datetime]::TryParse($text, $culture, [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) {
            return $parsed
        }
    }
    return $null
}

function Format-ValidationNumber {
    param([AllowNull()][object]$Value, [string]$Format = "N2")
    $number = ConvertTo-ValidationNumber $Value
    if ($null -eq $number) { return "-" }
    return $number.ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-ValidationPercent {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return "-" }
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:+0.0;-0.0;0.0}%", [double]$Value)
}

function Get-ValidationRowValue {
    param([AllowNull()][object]$Row, [string]$Field)
    if ($null -eq $Row -or [string]::IsNullOrWhiteSpace($Field)) { return $null }
    foreach ($name in @("[$Field]", $Field)) {
        $property = $Row.PSObject.Properties[$name]
        if ($null -ne $property) { return $property.Value }
    }
    return $null
}

function Invoke-ValidationQuery {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceId,
        [Parameter(Mandatory = $true)][string]$DatasetId,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$Query
    )

    $uri = "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/datasets/$DatasetId/executeQueries"
    $body = @{
        queries = @(@{ query = $Query })
        serializerSettings = @{ includeNulls = $true }
    } | ConvertTo-Json -Depth 6

    try {
        $response = Invoke-RestMethod -Method POST -Uri $uri -Headers $Headers -Body $body -ContentType "application/json" -ErrorAction Stop
    } catch {
        # Windows PowerShell reports only the status line ("(400) Bad Request"); the DAX
        # message is in the response body, so read it and carry it in the error.
        $detail = ""
        $status = 0
        try {
            $webResponse = $_.Exception.Response
            if ($null -ne $webResponse) {
                $status = [int]$webResponse.StatusCode
                $reader = New-Object System.IO.StreamReader($webResponse.GetResponseStream())
                $detail = $reader.ReadToEnd()
                $reader.Dispose()
            }
        } catch { }
        if ([string]::IsNullOrWhiteSpace($detail)) { throw }
        throw ("Validation query failed with HTTP {0}: {1}" -f $status, $detail)
    }
    $result = @($response.results)[0]
    $table = @($result.tables)[0]
    return @(@($table.rows) | Where-Object { $null -ne $_ })
}

function Resolve-ValidationTarget {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceName,
        [Parameter(Mandatory = $true)][string]$ReportName,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    $groups = @((Invoke-RestMethod -Method GET -Uri "https://api.powerbi.com/v1.0/myorg/groups" -Headers $Headers -ErrorAction Stop).value)
    $foundWorkspaces = @($groups | Where-Object { ([string]$_.name).Trim() -ieq $WorkspaceName.Trim() })
    if ($foundWorkspaces.Count -ne 1) {
        throw "Expected exactly one workspace named '$WorkspaceName', found $($foundWorkspaces.Count)."
    }
    $workspace = $foundWorkspaces[0]

    $reports = @((Invoke-RestMethod -Method GET -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($workspace.id)/reports" -Headers $Headers -ErrorAction Stop).value)
    $foundReports = @($reports | Where-Object { ([string]$_.name).Trim() -ieq $ReportName.Trim() })
    if ($foundReports.Count -ne 1) {
        throw "Expected exactly one report named '$ReportName' in workspace '$WorkspaceName', found $($foundReports.Count)."
    }
    $report = $foundReports[0]
    $datasetId = [string]$report.datasetId
    if ([string]::IsNullOrWhiteSpace($datasetId)) {
        throw "Report '$ReportName' has no semantic model attached."
    }

    $modelWorkspaceId = [string]$workspace.id
    $readable = $false
    try {
        Invoke-RestMethod -Method GET -Uri "https://api.powerbi.com/v1.0/myorg/groups/$modelWorkspaceId/datasets/$datasetId" -Headers $Headers -ErrorAction Stop | Out-Null
        $readable = $true
    } catch {
        foreach ($group in $groups) {
            try {
                Invoke-RestMethod -Method GET -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($group.id)/datasets/$datasetId" -Headers $Headers -ErrorAction Stop | Out-Null
                $modelWorkspaceId = [string]$group.id
                $readable = $true
                break
            } catch { }
        }
    }
    if (-not $readable) {
        throw "The semantic model of report '$ReportName' could not be read in any accessible workspace."
    }

    return [pscustomobject][ordered]@{
        workspaceId = [string]$workspace.id
        workspaceName = [string]$workspace.name
        reportName = [string]$report.name
        datasetId = $datasetId
        modelWorkspaceId = $modelWorkspaceId
    }
}

function Resolve-ValidationArtifactsRoot {
    # Order: explicit parameter, POWERBI_VALIDATION_ARTIFACTS_ROOT, the config's
    # artifactsRoot, then the per-user default. Environment variables such as
    # %LOCALAPPDATA% are expanded; a relative path resolves against the tool folder.
    param(
        [Parameter(Mandatory = $true)][string]$ConfigRoot,
        [AllowNull()][string]$Setting,
        [AllowNull()][string]$Override
    )

    $value = $Override
    if ([string]::IsNullOrWhiteSpace($value)) { $value = Get-ValidationConfigValue "POWERBI_VALIDATION_ARTIFACTS_ROOT" }
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $Setting }
    if ([string]::IsNullOrWhiteSpace($value)) { $value = "%LOCALAPPDATA%\PowerBIValidation\reports" }
    $value = [Environment]::ExpandEnvironmentVariables($value)
    if ([System.IO.Path]::IsPathRooted($value)) { return $value }
    return (Join-Path $ConfigRoot $value)
}

function Enter-ValidationLock {
    # One active run per report. The lock file records the owner's process id and
    # start time, so a lock left behind by a killed process is recognised as stale.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$RunFolder = ""
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
                throw "Another validation run is already active for this report (process $($holder.pid) on $($holder.computer), run folder $($holder.runFolder)). Nothing was started."
            }
            Remove-Item -LiteralPath $Path -Force
        }
    }
    throw "The run lock could not be acquired: $Path"
}

function Exit-ValidationLock {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $holder = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ([int]$holder.pid -eq $PID) { Remove-Item -LiteralPath $Path -Force }
    } catch { }
}

function Test-ValidationRefreshInProgress {
    # The service reports a refresh that is still running with status "Unknown".
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Target,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    $uri = "https://api.powerbi.com/v1.0/myorg/groups/$($Target.modelWorkspaceId)/datasets/$($Target.datasetId)/refreshes?`$top=1"
    $latest = @((Invoke-RestMethod -Method GET -Uri $uri -Headers $Headers -ErrorAction Stop).value) | Select-Object -First 1
    return ($null -ne $latest -and [string]$latest.status -eq "Unknown")
}

function Find-ValidationChainRun {
    # The chained refresh writes its own run folder. Pick the new folder that
    # belongs to this workspace and report, so a run started by someone else at
    # the same time is never mistaken for ours.
    param(
        [Parameter(Mandatory = $true)][string]$RunsRoot,
        [string[]]$ExistingNames = @(),
        [Parameter(Mandatory = $true)][string]$WorkspaceName,
        [Parameter(Mandatory = $true)][string]$ReportName
    )

    if (-not (Test-Path -LiteralPath $RunsRoot)) { return $null }
    $newFolders = @(Get-ChildItem -LiteralPath $RunsRoot -Directory | Where-Object { $ExistingNames -notcontains $_.Name } | Sort-Object Name -Descending)
    foreach ($folder in $newFolders) {
        $summaryPath = Join-Path $folder.FullName "summary.json"
        if (Test-Path -LiteralPath $summaryPath) {
            try { $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json } catch { continue }
            if ([string]$summary.Workspace -ieq $WorkspaceName -and [string]$summary.Report -ieq $ReportName) {
                return [pscustomobject]@{ Folder = $folder.FullName; Summary = $summary }
            }
            continue
        }
        $logPath = Join-Path $folder.FullName "refresh-log.txt"
        if (Test-Path -LiteralPath $logPath) {
            $firstLines = (Get-Content -LiteralPath $logPath -TotalCount 3) -join " "
            if ($firstLines -like "*Starting report '$ReportName' in workspace '$WorkspaceName'*") {
                return [pscustomobject]@{ Folder = $folder.FullName; Summary = $null }
            }
        }
    }
    return $null
}

function Get-ValidationReportKey {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceName,
        [Parameter(Mandatory = $true)][string]$ReportName
    )

    $key = "$WorkspaceName - $ReportName"
    foreach ($invalid in [System.IO.Path]::GetInvalidFileNameChars()) {
        $key = $key.Replace([string]$invalid, "-")
    }
    $key = $key.Trim().TrimEnd(".")
    if ([string]::IsNullOrWhiteSpace($key)) { $key = "unnamed-report" }
    return $key
}

function Resolve-ValidationBaseline {
    param(
        [Parameter(Mandatory = $true)][string]$RunsRoot,
        [Parameter(Mandatory = $true)][int]$RunsBack,
        [string]$ExcludeRunFolder,
        [string]$WorkspaceName,
        [string]$ReportName
    )

    $candidates = @()
    if (Test-Path -LiteralPath $RunsRoot) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $RunsRoot -Directory | Sort-Object Name -Descending)) {
            if (-not [string]::IsNullOrWhiteSpace($ExcludeRunFolder) -and $folder.FullName -eq $ExcludeRunFolder) { continue }
            $summaryPath = Join-Path $folder.FullName "validation-summary.json"
            $afterPath = Join-Path $folder.FullName "after.json"
            if (-not (Test-Path -LiteralPath $summaryPath) -or -not (Test-Path -LiteralPath $afterPath)) { continue }
            try { $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json } catch { continue }
            if ([string]$summary.refreshResult -ne "Succeeded") { continue }
            if (-not [string]::IsNullOrWhiteSpace([string]$summary.fatalError)) { continue }
            if (-not [string]::IsNullOrWhiteSpace($WorkspaceName) -and [string]$summary.workspaceName -ine $WorkspaceName) { continue }
            if (-not [string]::IsNullOrWhiteSpace($ReportName) -and [string]$summary.reportName -ine $ReportName) { continue }
            # A FAIL run is a baseline only after someone accepted it with accepted.json.
            if ([string]$summary.validationResult -eq "FAIL" -and -not (Test-Path -LiteralPath (Join-Path $folder.FullName "accepted.json"))) { continue }
            # A snapshot with query errors (for example an expired token) is not data.
            try { $afterSnapshot = Get-Content -LiteralPath $afterPath -Raw | ConvertFrom-Json } catch { continue }
            if (@($afterSnapshot.checks | Where-Object { [string]$_.status -eq "Error" }).Count -gt 0) { continue }
            $candidates += [pscustomobject]@{ Folder = $folder; Summary = $summary }
        }
    }
    if ($RunsBack -lt 1) { throw "RunsBack must be 1 or greater." }
    if ($RunsBack -gt $candidates.Count) {
        throw "Only $($candidates.Count) previous usable run(s) are available, but run number $RunsBack back was requested. A usable run has a successful refresh, a post-check without query errors, and no FAIL verdict unless accepted."
    }
    return $candidates[$RunsBack - 1]
}

function Get-ValidationSnapshot {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [Parameter(Mandatory = $true)][pscustomobject]$Target,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    $checks = @()
    foreach ($check in @($Config.checks)) {
        $entry = [ordered]@{
            id = [string]$check.id
            label = [string]$check.label
            kind = [string]$check.kind
            status = "Ok"
            error = ""
            value = $null
            values = @()
            rowCount = 0
        }
        try {
            if ([string]$check.kind -eq "table_rows") {
                # Universal check: the query is built from the model's own table list.
                $items = @(Get-ValidationTableRows -Target $Target -Headers $Headers)
                $entry.values = $items
                $entry.rowCount = $items.Count
                $checks += [pscustomobject]$entry
                continue
            }
            $query = [string]$check.query
            if ($null -ne $check.monthsBack) {
                $query = $query.Replace("{monthsBack}", [string]([int]$check.monthsBack))
            }
            $rows = @(Invoke-ValidationQuery -WorkspaceId $Target.modelWorkspaceId -DatasetId $Target.datasetId -Headers $Headers -Query $query)
            if ([string]$check.kind -eq "table") {
                $items = @()
                foreach ($row in $rows) {
                    $items += [pscustomobject][ordered]@{
                        key = [string](Get-ValidationRowValue -Row $row -Field ([string]$check.keyField))
                        value = Get-ValidationRowValue -Row $row -Field ([string]$check.valueField)
                    }
                }
                $entry.values = $items
                $entry.rowCount = $items.Count
            } else {
                $row = @($rows)[0]
                $entry.value = Get-ValidationRowValue -Row $row -Field ([string]$check.valueField)
                $entry.rowCount = $rows.Count
            }
        } catch {
            $entry.status = "Error"
            $entry.error = $_.Exception.Message
        }
        $checks += [pscustomobject]$entry
    }

    $snapshot = [ordered]@{
        capturedAt = (Get-Date).ToString("o")
        workspaceName = [string]$Config.workspaceName
        reportName = [string]$Config.reportName
        checks = $checks
    }
    if ($null -ne $Config.PSObject.Properties["modelStructure"] -and [bool]$Config.modelStructure) {
        $snapshot.structure = Get-ValidationStructure -Target $Target -Headers $Headers
    }
    return [pscustomobject]$snapshot
}

# Model structure: object names read through the INFO.VIEW functions, which work
# with read access through executeQueries for any model (the older INFO.* DMV
# functions need admin rights and are refused). Kept apart from the checks: it is
# shown in the email but never decides a verdict or stops a run.
$script:ValidationStructureParts = @(
    [pscustomobject]@{ id = "tables"; label = "Tables"; query = 'EVALUATE SELECTCOLUMNS(INFO.VIEW.TABLES(), "Key", [Name])' },
    # RowNumber is an internal column that every table has.
    [pscustomobject]@{ id = "columns"; label = "Columns"; query = 'EVALUATE SELECTCOLUMNS(FILTER(INFO.VIEW.COLUMNS(), [Type] <> "RowNumber"), "Key", "''" & [Table] & "''[" & [Name] & "]")' },
    [pscustomobject]@{ id = "measures"; label = "Measures"; query = 'EVALUATE SELECTCOLUMNS(INFO.VIEW.MEASURES(), "Key", [Name])' },
    # [Relationship] reads like 'Fact'[Key] *[<-]1 'Dim'[Key], so a changed
    # cardinality or filter direction shows as one removed and one added.
    [pscustomobject]@{ id = "relationships"; label = "Relationships"; query = 'EVALUATE SELECTCOLUMNS(INFO.VIEW.RELATIONSHIPS(), "Key", [Relationship])' }
)

function Get-ValidationStructure {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Target,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )
    $parts = @()
    foreach ($part in $script:ValidationStructureParts) {
        $entry = [ordered]@{ id = $part.id; label = $part.label; status = "Ok"; error = ""; items = @() }
        try {
            $rows = @(Invoke-ValidationQuery -WorkspaceId $Target.modelWorkspaceId -DatasetId $Target.datasetId -Headers $Headers -Query $part.query)
            $entry.items = @($rows | ForEach-Object { [string](Get-ValidationRowValue -Row $_ -Field "Key") } | Where-Object { $_ -ne "" } | Sort-Object -Unique)
        } catch {
            $entry.status = "Error"
            $entry.error = Get-ValidationSafeText $_.Exception.Message
        }
        $parts += [pscustomobject]$entry
    }
    return $parts
}

# --- Universal checks: work for any model, no report config needed ---------------------

function ConvertTo-ValidationDaxTableName {
    # 'Table name' with embedded quotes doubled.
    param([Parameter(Mandatory = $true)][string]$Name)
    return "'" + $Name.Replace("'", "''") + "'"
}

function ConvertTo-ValidationDaxString {
    param([Parameter(Mandatory = $true)][string]$Text)
    return '"' + $Text.Replace('"', '""') + '"'
}

function Test-ValidationCountedTable {
    # A table whose rows are worth counting: not an automatic date table, not a
    # calculation group (its "rows" are calculation items), and stored in memory
    # (counting a DirectQuery table would send a query to the source system).
    param([Parameter(Mandatory = $true)][object]$Row)

    $name = [string](Get-ValidationRowValue -Row $Row -Field "Name")
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    if ($name.StartsWith("LocalDateTable_") -or $name.StartsWith("DateTableTemplate_")) { return $false }
    if ([string](Get-ValidationRowValue -Row $Row -Field "IsPrivate") -ieq "True") { return $false }
    $precedence = Get-ValidationRowValue -Row $Row -Field "CalculationGroupPrecedence"
    if ($null -ne $precedence -and -not [string]::IsNullOrWhiteSpace([string]$precedence)) { return $false }
    $storage = [string](Get-ValidationRowValue -Row $Row -Field "StorageMode")
    if (-not [string]::IsNullOrWhiteSpace($storage) -and $storage -notin @("Import", "Dual")) { return $false }
    return $true
}

function Get-ValidationTableRows {
    # Row count of every counted table, read with three DAX queries: the table list
    # (INFO.VIEW.TABLES, readable with dataset read access), the list of tables that
    # have at least one visible column, and one UNION of COUNTROWS.
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Target,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    $tableRows = @(Invoke-ValidationQuery -WorkspaceId $Target.modelWorkspaceId -DatasetId $Target.datasetId -Headers $Headers -Query 'EVALUATE SELECTCOLUMNS(INFO.VIEW.TABLES(), "Name", [Name], "IsPrivate", [IsPrivate], "StorageMode", [StorageMode], "CalculationGroupPrecedence", [CalculationGroupPrecedence])')
    $names = @($tableRows | Where-Object { Test-ValidationCountedTable $_ } | ForEach-Object { [string](Get-ValidationRowValue -Row $_ -Field "Name") } | Sort-Object -Unique)
    if ($names.Count -eq 0) { return @() }
    # A table with no visible columns (for example a measures-only table) cannot be
    # counted: one COUNTROWS on it fails the whole UNION with "Table ... cannot be
    # used in computations because it does not have any columns" (HTTP 400).
    $columnRows = @(Invoke-ValidationQuery -WorkspaceId $Target.modelWorkspaceId -DatasetId $Target.datasetId -Headers $Headers -Query 'EVALUATE SELECTCOLUMNS(FILTER(INFO.VIEW.COLUMNS(), [Type] <> "RowNumber"), "Table", [Table])')
    $tablesWithColumns = @($columnRows | ForEach-Object { [string](Get-ValidationRowValue -Row $_ -Field "Table") })
    $names = @($names | Where-Object { $tablesWithColumns -contains $_ })
    if ($names.Count -eq 0) { return @() }
    $parts = @($names | ForEach-Object { "ROW(""Table"", $(ConvertTo-ValidationDaxString $_), ""Rows"", COUNTROWS($(ConvertTo-ValidationDaxTableName $_)))" })
    $query = if ($parts.Count -eq 1) { "EVALUATE " + $parts[0] } else { "EVALUATE UNION(" + ($parts -join ", ") + ")" }
    $rows = @(Invoke-ValidationQuery -WorkspaceId $Target.modelWorkspaceId -DatasetId $Target.datasetId -Headers $Headers -Query $query)
    $items = @()
    foreach ($row in $rows) {
        $value = ConvertTo-ValidationNumber (Get-ValidationRowValue -Row $row -Field "Rows")
        # COUNTROWS of an empty table is blank, which means zero rows.
        if ($null -eq $value) { $value = 0 }
        $items += [pscustomobject][ordered]@{ key = [string](Get-ValidationRowValue -Row $row -Field "Table"); value = $value }
    }
    return @($items | Sort-Object key)
}

function New-ValidationUniversalConfig {
    # The checks for a model without a report config, from universal-checks.json next
    # to this file, with this run's names filled in.
    param(
        [string]$WorkspaceName = "",
        [string]$ReportName = "",
        [string]$ModelName = "",
        [string]$ToolRoot = $PSScriptRoot
    )

    $config = Read-ValidationConfig -Path (Join-Path $ToolRoot "universal-checks.json")
    foreach ($pair in @(@("workspaceName", $WorkspaceName), @("reportName", $(if ($ReportName) { $ReportName } else { $ModelName })), @("semanticModelName", $ModelName), @("universal", $true))) {
        $config | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force
    }
    return $config
}

function Find-ValidationConfigForModel {
    # The report config for a semantic model, matched by workspace name and model name
    # (or, for a config without semanticModelName, by report name). Null when none
    # matches; the caller then uses the universal checks.
    param(
        [string]$WorkspaceName,
        [string]$ModelName,
        [string]$ReportName = "",
        [string]$ToolRoot = $PSScriptRoot
    )

    $folder = Join-Path $ToolRoot "reports"
    foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -Filter "*.config.json" -ErrorAction SilentlyContinue | Sort-Object Name)) {
        try { $config = Read-ValidationConfig -Path $file.FullName } catch { continue }
        if ([string]$config.workspaceName -ine ([string]$WorkspaceName).Trim()) { continue }
        $configModel = [string]$config.semanticModelName
        $matched = if (-not [string]::IsNullOrWhiteSpace($configModel)) { $configModel -ieq ([string]$ModelName).Trim() } else { $ReportName -and ([string]$config.reportName -ieq $ReportName.Trim()) }
        if ($matched) {
            $config | Add-Member -NotePropertyName configPath -NotePropertyValue $file.FullName -Force
            return $config
        }
    }
    return $null
}

function Compare-ValidationStructure {
    # Counts and the names added or removed, per object type. Returns an empty list
    # when neither snapshot has a structure (older runs, or the switch is off).
    param([AllowNull()][object]$Before, [AllowNull()][object]$After)
    $beforeParts = if ($null -ne $Before -and $null -ne $Before.PSObject.Properties["structure"]) { @($Before.structure) } else { @() }
    $afterParts = if ($null -ne $After -and $null -ne $After.PSObject.Properties["structure"]) { @($After.structure) } else { @() }
    if ($beforeParts.Count -eq 0 -and $afterParts.Count -eq 0) { return @() }

    $results = @()
    foreach ($part in $script:ValidationStructureParts) {
        $old = @($beforeParts | Where-Object { [string]$_.id -eq $part.id }) | Select-Object -First 1
        $new = @($afterParts | Where-Object { [string]$_.id -eq $part.id }) | Select-Object -First 1
        $oldOk = $null -ne $old -and [string]$old.status -eq "Ok"
        $newOk = $null -ne $new -and [string]$new.status -eq "Ok"
        # Assigned directly: an "if" expression would turn an empty list into $null.
        [string[]]$oldItems = @()
        [string[]]$newItems = @()
        if ($oldOk) { $oldItems = @($old.items | ForEach-Object { [string]$_ }) }
        if ($newOk) { $newItems = @($new.items | ForEach-Object { [string]$_ }) }
        $errors = @()
        if ($null -ne $old -and -not $oldOk) { $errors += "before: $($old.error)" }
        if ($null -ne $new -and -not $newOk) { $errors += "after: $($new.error)" }
        $added = @()
        $removed = @()
        if ($oldOk -and $newOk) {
            # Ordinal and case-sensitive: a renamed case is a real change in the model.
            $oldSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$oldItems, [StringComparer]::Ordinal)
            $newSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$newItems, [StringComparer]::Ordinal)
            $added = @($newItems | Where-Object { -not $oldSet.Contains($_) })
            $removed = @($oldItems | Where-Object { -not $newSet.Contains($_) })
        }
        $results += [pscustomobject][ordered]@{
            id = $part.id
            label = $part.label
            before = if ($oldOk) { $oldItems.Count } else { $null }
            after = if ($newOk) { $newItems.Count } else { $null }
            added = $added
            removed = $removed
            error = ($errors -join "; ")
        }
    }
    return $results
}

function Get-ValidationWorstVerdict {
    param([string[]]$Verdicts)
    if (@($Verdicts) -contains "FAIL") { return "FAIL" }
    if (@($Verdicts) -contains "WARN") { return "WARN" }
    return "PASS"
}

function Compare-ValidationSnapshots {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Before,
        [Parameter(Mandatory = $true)][pscustomobject]$After,
        [Parameter(Mandatory = $true)][pscustomobject]$Config
    )

    $results = @()
    foreach ($beforeCheck in @($Before.checks)) {
        # A baseline from an older run can hold checks that were removed from the
        # config since. They are not part of this report any more, so skip them.
        if (@($Config.checks | Where-Object { $null -ne $_ -and [string]$_.id -eq [string]$beforeCheck.id }).Count -eq 0) { continue }
        $afterCheck = @($After.checks | Where-Object { [string]$_.id -eq [string]$beforeCheck.id }) | Select-Object -First 1
        $result = [ordered]@{
            id = [string]$beforeCheck.id
            label = [string]$beforeCheck.label
            kind = [string]$beforeCheck.kind
            verdict = "PASS"
            message = ""
            before = $null
            after = $null
            delta = $null
            percent = $null
            months = @()
        }

        if ($null -eq $afterCheck) {
            $result.verdict = "FAIL"
            $result.message = "The check is missing from the post-refresh snapshot."
            $results += [pscustomobject]$result
            continue
        }
        if ([string]$beforeCheck.status -eq "Error" -or [string]$afterCheck.status -eq "Error") {
            $result.verdict = "FAIL"
            $messages = @()
            if (-not [string]::IsNullOrWhiteSpace([string]$beforeCheck.error)) { $messages += "Pre-check: $($beforeCheck.error)" }
            if (-not [string]::IsNullOrWhiteSpace([string]$afterCheck.error)) { $messages += "Post-check: $($afterCheck.error)" }
            $result.message = ($messages -join " ")
            $results += [pscustomobject]$result
            continue
        }

        $warnPercent = 10
        $failPercent = 25
        $mustAdvance = $false
        $maxAgeMonths = $null
        $dateFormat = "yyyy-MM-dd"
        $zeroVerdict = "WARN"
        $configCheck = @($Config.checks | Where-Object { [string]$_.id -eq [string]$beforeCheck.id }) | Select-Object -First 1
        if ($null -ne $configCheck) {
            if ($null -ne $configCheck.warnPercent) { $warnPercent = [double]$configCheck.warnPercent }
            if ($null -ne $configCheck.failPercent) { $failPercent = [double]$configCheck.failPercent }
            if ($null -ne $configCheck.mustAdvance) { $mustAdvance = [bool]$configCheck.mustAdvance }
            if ($null -ne $configCheck.maxAgeMonths) { $maxAgeMonths = [int]$configCheck.maxAgeMonths }
            if (-not [string]::IsNullOrWhiteSpace([string]$configCheck.dateFormat)) { $dateFormat = [string]$configCheck.dateFormat }
            if (-not [string]::IsNullOrWhiteSpace([string]$configCheck.zeroVerdict)) { $zeroVerdict = [string]$configCheck.zeroVerdict }
        }

        switch ([string]$beforeCheck.kind) {
            "table" {
                $beforeMap = @{}
                foreach ($item in @($beforeCheck.values)) { $beforeMap[[string]$item.key] = $item }
                $months = @()
                $verdicts = @()

                foreach ($item in @($afterCheck.values)) {
                    $key = [string]$item.key
                    $newValue = ConvertTo-ValidationNumber $item.value
                    $oldItem = $beforeMap[$key]
                    $oldValue = $null
                    if ($null -ne $oldItem) { $oldValue = ConvertTo-ValidationNumber $oldItem.value }

                    $monthVerdict = "PASS"
                    $monthMessage = ""
                    $percent = $null
                    if ($null -eq $oldItem) {
                        $monthMessage = "New month"
                    } elseif ($null -eq $newValue) {
                        $monthVerdict = "FAIL"
                        $monthMessage = "No value after refresh"
                    } elseif ($newValue -eq 0) {
                        $monthVerdict = "FAIL"
                        $monthMessage = "No rows after refresh"
                    } elseif ($null -ne $oldValue -and $oldValue -ne 0) {
                        $percent = (($newValue - $oldValue) / $oldValue) * 100
                        if ([math]::Abs($percent) -ge $failPercent) { $monthVerdict = "FAIL" }
                        elseif ([math]::Abs($percent) -ge $warnPercent) { $monthVerdict = "WARN" }
                    }

                    $verdicts += $monthVerdict
                    $months += [pscustomobject][ordered]@{
                        key = $key
                        before = $oldValue
                        after = $newValue
                        percent = $percent
                        verdict = $monthVerdict
                        message = $monthMessage
                    }
                }

                # When the latest month advances, the window moves forward and its first
                # month drops out. That month is outside the new window, not missing, so
                # only months at or after the new window start can be missing.
                $afterKeys = @($afterCheck.values | ForEach-Object { [string]$_.key })
                $windowStart = @($afterKeys | Sort-Object) | Select-Object -First 1
                foreach ($key in @($beforeMap.Keys)) {
                    if ($null -ne $windowStart -and [string]::CompareOrdinal($key, $windowStart) -lt 0) { continue }
                    if ($afterKeys -notcontains $key) {
                        $verdicts += "FAIL"
                        $months += [pscustomobject][ordered]@{
                            key = $key
                            before = (ConvertTo-ValidationNumber $beforeMap[$key].value)
                            after = $null
                            percent = $null
                            verdict = "FAIL"
                            message = "Month missing after refresh"
                        }
                    }
                }

                $result.months = @($months | Sort-Object key)
                $result.verdict = Get-ValidationWorstVerdict $verdicts
                $attention = @($months | Where-Object { $_.verdict -ne "PASS" })
                if ($attention.Count -gt 0) {
                    $result.message = (($attention | ForEach-Object { $_.key }) -join ", ") + " need attention"
                }
            }
            "table_rows" {
                # Rows per table, keyed by table name. Unlike the monthly "table" kind
                # there is no window: a table that is gone is reported, a new one is
                # noted, and a table with data that comes back empty fails.
                $beforeMap = @{}
                foreach ($item in @($beforeCheck.values)) { $beforeMap[[string]$item.key] = $item }
                $afterMap = @{}
                foreach ($item in @($afterCheck.values)) { $afterMap[[string]$item.key] = $item }
                $rows = @()
                $verdicts = @()
                foreach ($key in @(@($beforeMap.Keys) + @($afterMap.Keys) | Sort-Object -Unique)) {
                    $oldValue = if ($beforeMap.ContainsKey($key)) { ConvertTo-ValidationNumber $beforeMap[$key].value } else { $null }
                    $newValue = if ($afterMap.ContainsKey($key)) { ConvertTo-ValidationNumber $afterMap[$key].value } else { $null }
                    $rowVerdict = "PASS"
                    $rowMessage = ""
                    $percent = $null
                    if (-not $beforeMap.ContainsKey($key)) {
                        $rowMessage = "New table"
                    } elseif (-not $afterMap.ContainsKey($key)) {
                        $rowVerdict = "WARN"
                        $rowMessage = "Table no longer counted"
                    } elseif ($null -ne $oldValue -and $oldValue -gt 0 -and $newValue -eq 0) {
                        $rowVerdict = "FAIL"
                        $rowMessage = "No rows after refresh"
                    } elseif ($null -ne $oldValue -and $oldValue -ne 0 -and $null -ne $newValue) {
                        $percent = (($newValue - $oldValue) / $oldValue) * 100
                        if ([math]::Abs($percent) -ge $failPercent) { $rowVerdict = "FAIL" }
                        elseif ([math]::Abs($percent) -ge $warnPercent) { $rowVerdict = "WARN" }
                    } elseif (($null -eq $oldValue -or $oldValue -eq 0) -and $null -ne $newValue -and $newValue -gt 0) {
                        $rowMessage = "Was empty"
                    }
                    $verdicts += $rowVerdict
                    $rows += [pscustomobject][ordered]@{ key = $key; before = $oldValue; after = $newValue; percent = $percent; verdict = $rowVerdict; message = $rowMessage }
                }
                $result.months = @($rows)
                $result.verdict = Get-ValidationWorstVerdict $verdicts
                $paired = @($rows | Where-Object { $null -ne $_.before -and $null -ne $_.after })
                if ($paired.Count -gt 0) {
                    $result.before = [double](($paired | ForEach-Object { [double]$_.before } | Measure-Object -Sum).Sum)
                    $result.after = [double](($paired | ForEach-Object { [double]$_.after } | Measure-Object -Sum).Sum)
                    $result.delta = $result.after - $result.before
                    if ($result.before -ne 0) { $result.percent = ($result.delta / $result.before) * 100 }
                }
                $attention = @($rows | Where-Object { $_.verdict -ne "PASS" })
                if ($attention.Count -gt 0) { $result.message = (($attention | ForEach-Object { $_.key }) -join ", ") + " need attention" }
            }
            "scalar_date" {
                $oldDate = ConvertTo-ValidationDate $beforeCheck.value
                $newDate = ConvertTo-ValidationDate $afterCheck.value
                $result.before = if ($null -ne $oldDate) { $oldDate.ToString($dateFormat, [System.Globalization.CultureInfo]::InvariantCulture) } else { $beforeCheck.value }
                $result.after = if ($null -ne $newDate) { $newDate.ToString($dateFormat, [System.Globalization.CultureInfo]::InvariantCulture) } else { $afterCheck.value }

                if ($null -eq $newDate) {
                    $result.verdict = "FAIL"
                    $result.message = "No date after refresh"
                } elseif ($null -ne $oldDate -and $newDate -lt $oldDate) {
                    $result.verdict = "FAIL"
                    $result.message = "The latest date moved backwards"
                } elseif ($null -ne $maxAgeMonths) {
                    # Cadence-aware: data arrives monthly, so an unchanged date is normal
                    # until it is older than the expected lag.
                    $today = if ($null -ne $Config.PSObject.Properties["evaluationDate"] -and $Config.evaluationDate) { [datetime]$Config.evaluationDate } else { Get-Date }
                    $oldest = (New-Object DateTime($today.Year, $today.Month, 1)).AddMonths(-$maxAgeMonths)
                    if ($newDate -ge $oldest) {
                        $result.verdict = "PASS"
                        if ($null -ne $oldDate -and $newDate -eq $oldDate) { $result.message = "Unchanged; within the expected $maxAgeMonths-month lag" }
                    } else {
                        $result.verdict = "WARN"
                        $result.message = "Older than $maxAgeMonths month(s); new data may be late"
                    }
                } elseif ($null -eq $oldDate) {
                    $result.verdict = "PASS"
                    $result.message = "No previous date"
                } elseif ($newDate -gt $oldDate) {
                    $result.verdict = "PASS"
                } elseif ($newDate -eq $oldDate) {
                    if ($mustAdvance) {
                        $result.verdict = "WARN"
                        $result.message = "No new data arrived"
                    } else {
                        $result.verdict = "PASS"
                    }
                } else {
                    $result.verdict = "FAIL"
                    $result.message = "The latest date moved backwards"
                }
            }
            default {
                $oldValue = ConvertTo-ValidationNumber $beforeCheck.value
                $newValue = ConvertTo-ValidationNumber $afterCheck.value
                $result.before = $oldValue
                $result.after = $newValue

                if ($null -eq $newValue) {
                    $result.verdict = "FAIL"
                    $result.message = "No value after refresh"
                } elseif ($newValue -eq 0) {
                    $result.verdict = $zeroVerdict
                    $result.message = "The value is zero"
                } elseif ($null -eq $oldValue) {
                    $result.verdict = "PASS"
                    $result.message = "No previous value"
                } else {
                    $delta = $newValue - $oldValue
                    $result.delta = $delta
                    if ($oldValue -ne 0) {
                        $percent = ($delta / $oldValue) * 100
                        $result.percent = $percent
                        if ([math]::Abs($percent) -ge $failPercent) { $result.verdict = "FAIL" }
                        elseif ([math]::Abs($percent) -ge $warnPercent) { $result.verdict = "WARN" }
                    }
                }
            }
        }

        $results += [pscustomobject]$result
    }

    foreach ($derived in @($Config.derivedChecks)) {
        if ($null -eq $derived) { continue }
        $source = @($results | Where-Object { [string]$_.id -eq [string]$derived.sourceCheckId }) | Select-Object -First 1
        $rowSource = @($results | Where-Object { [string]$_.id -eq [string]$derived.rowCountCheckId }) | Select-Object -First 1
        $result = [ordered]@{
            id = [string]$derived.id
            label = [string]$derived.label
            kind = "derived"
            verdict = "WARN"
            message = ""
            before = $null
            after = $null
            delta = $null
            percent = $null
            months = @()
        }

        if ($null -eq $source -or @($source.months).Count -eq 0) {
            $result.verdict = "FAIL"
            $result.message = "Source check '$($derived.sourceCheckId)' produced no monthly data."
            $results += [pscustomobject]$result
            continue
        }

        $rowMap = @{}
        if ($null -ne $rowSource) {
            foreach ($month in @($rowSource.months)) { $rowMap[[string]$month.key] = $month.after }
        }

        $months = @($source.months | Where-Object { $null -ne $_.after } | Sort-Object key)
        $minRowRatio = if ($null -ne $derived.minRowRatio) { [double]$derived.minRowRatio } else { 0.8 }
        $complete = @()
        for ($i = 0; $i -lt $months.Count; $i++) {
            $month = $months[$i]
            $isComplete = $true
            if ($rowMap.Count -gt 0) {
                $priorRows = @()
                for ($j = [int][math]::Max(0, $i - 3); $j -lt $i; $j++) {
                    $value = ConvertTo-ValidationNumber $rowMap[[string]$months[$j].key]
                    if ($null -ne $value) { $priorRows += $value }
                }
                if ($priorRows.Count -ge 3) {
                    $reference = ($priorRows | Measure-Object -Average).Average
                    $currentRows = ConvertTo-ValidationNumber $rowMap[[string]$month.key]
                    if ($null -ne $currentRows -and $reference -gt 0 -and $currentRows -lt ($reference * $minRowRatio)) {
                        $isComplete = $false
                    }
                }
            }
            if ($isComplete) { $complete += $month }
        }

        if ($complete.Count -eq 0) {
            $result.verdict = "FAIL"
            $result.message = "No complete month was found in the source check."
            $results += [pscustomobject]$result
            continue
        }

        $latest = $complete[$complete.Count - 1]
        $warnDeviation = if ($null -ne $derived.warnDeviationPercent) { [double]$derived.warnDeviationPercent } else { 40 }
        $failDeviation = if ($null -ne $derived.failDeviationPercent) { [double]$derived.failDeviationPercent } else { 70 }

        if ([string]$derived.comparison -eq "lastYear") {
            # Same month one year earlier. Monthly business data is often strongly
            # seasonal (a report whose figures peak every December), so this is far
            # steadier than a rolling average.
            $latestDate = [datetime]::MinValue
            if (-not [datetime]::TryParseExact(([string]$latest.key) + "-01", "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$latestDate)) {
                $result.verdict = "WARN"
                $result.message = "Month key '$($latest.key)' is not in yyyy-MM format; cannot find the same month last year."
                $results += [pscustomobject]$result
                continue
            }
            $priorKey = $latestDate.AddYears(-1).ToString("yyyy-MM", [System.Globalization.CultureInfo]::InvariantCulture)
            $prior = @($source.months | Where-Object { [string]$_.key -eq $priorKey }) | Select-Object -First 1
            $latestValue = ConvertTo-ValidationNumber $latest.after
            $priorValue = if ($null -ne $prior) { ConvertTo-ValidationNumber $prior.after } else { $null }
            $result.after = $latestValue
            $result.before = $priorValue
            if ($null -eq $priorValue -or $priorValue -eq 0 -or $null -eq $latestValue) {
                $result.verdict = "WARN"
                $result.message = "$($latest.key) has no comparable value for $priorKey (outside the window or zero)."
            } else {
                $deviation = (($latestValue - $priorValue) / $priorValue) * 100
                $result.percent = $deviation
                if ([math]::Abs($deviation) -ge $failDeviation) { $result.verdict = "FAIL" }
                elseif ([math]::Abs($deviation) -ge $warnDeviation) { $result.verdict = "WARN" }
                else { $result.verdict = "PASS" }
                $result.message = "$($latest.key) compared with $priorKey"
            }
            $results += [pscustomobject]$result
            continue
        }

        $take = if ($null -ne $derived.monthsAveraged) { [int]$derived.monthsAveraged } else { 6 }
        $history = @()
        for ($i = [int][math]::Max(0, $complete.Count - 1 - $take); $i -lt $complete.Count - 1; $i++) { $history += $complete[$i] }
        $historyValues = @($history | ForEach-Object { ConvertTo-ValidationNumber $_.after } | Where-Object { $null -ne $_ })

        if ($historyValues.Count -lt 2) {
            $result.verdict = "WARN"
            $result.message = "Not enough complete history months to compare."
            $results += [pscustomobject]$result
            continue
        }

        $average = ($historyValues | Measure-Object -Average).Average
        $latestValue = ConvertTo-ValidationNumber $latest.after
        $result.before = $average
        $result.after = $latestValue

        $deviation = $null
        if ($null -ne $latestValue -and $average -ne 0) {
            $deviation = (($latestValue - $average) / $average) * 100
            $result.percent = $deviation
        }

        if ($null -eq $latestValue) {
            $result.verdict = "FAIL"
            $result.message = "No value in the latest complete month."
        } elseif ($null -ne $deviation) {
            if ([math]::Abs($deviation) -ge $failDeviation) { $result.verdict = "FAIL" }
            elseif ([math]::Abs($deviation) -ge $warnDeviation) { $result.verdict = "WARN" }
            else { $result.verdict = "PASS" }
            $result.message = "$($latest.key) compared with the average of $($historyValues.Count) earlier complete months"
        } else {
            $result.verdict = "WARN"
            $result.message = "The history average is zero; deviation cannot be computed."
        }

        $results += [pscustomobject]$result
    }

    # Checks with "severity": "info" are shown but never decide the overall verdict.
    # The verdict their rule would have given is kept in ruleVerdict.
    $final = @()
    foreach ($item in $results) {
        $definition = @(@($Config.checks) + @($Config.derivedChecks) | Where-Object { $null -ne $_ -and [string]$_.id -eq [string]$item.id }) | Select-Object -First 1
        $item | Add-Member -NotePropertyName ruleVerdict -NotePropertyValue ([string]$item.verdict) -Force
        if ($null -ne $definition -and [string]$definition.severity -eq "info") { $item.verdict = "INFO" }
        $final += $item
    }
    $results = $final

    $infoCount = @($results | Where-Object { $_.verdict -eq "INFO" }).Count
    $passCount = @($results | Where-Object { $_.verdict -eq "PASS" }).Count
    $warnCount = @($results | Where-Object { $_.verdict -eq "WARN" }).Count
    $failCount = @($results | Where-Object { $_.verdict -eq "FAIL" }).Count
    $overall = if ($failCount -gt 0) { "FAIL" } elseif ($warnCount -gt 0) { "WARN" } else { "PASS" }

    return [pscustomobject][ordered]@{
        generatedAt = (Get-Date).ToString("o")
        overall = $overall
        counts = [pscustomobject][ordered]@{ total = $results.Count - $infoCount; pass = $passCount; warn = $warnCount; fail = $failCount; info = $infoCount }
        checks = $results
        structure = @(Compare-ValidationStructure -Before $Before -After $After)
    }
}

function ConvertTo-ValidationHtml {
    param([AllowNull()][object]$Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Format-ValidationCompletedAt {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return "-" }
    $parsed = ConvertTo-ValidationDate $Value
    if ($null -eq $parsed) { return ConvertTo-ValidationHtml ([string]$Value) }
    if ($parsed.Kind -eq [System.DateTimeKind]::Utc) { $parsed = $parsed.ToLocalTime() }
    return ConvertTo-ValidationHtml ($parsed.ToString("yyyy-MM-dd HH:mm:ss"))
}

function Get-ValidationVerdictText {
    # Verdict as bold coloured text, matching the Status column of the refresh table.
    param([string]$Verdict)
    $colors = @{ PASS = "#15803d"; WARN = "#a16207"; FAIL = "#b91c1c"; INFO = "#6b7280" }
    $color = $colors[$Verdict]
    if ($null -eq $color) { $color = "#374151" }
    return "<span style=`"font-weight:600;color:$color;`">$(ConvertTo-ValidationHtml $Verdict)</span>"
}

function Get-ValidationSectionHtml {
    # One validation section of the email: the checks of one semantic model, its
    # monthly or per-table detail, the model structure and the config's footnote.
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Compare,
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [string]$BaselineNote = "this run's pre-refresh snapshot"
    )

    $iconOk = [string][char]0x2705
    $iconWarn = [string][char]0x26A0
    $iconFail = [string][char]0x274C
    $thStyle = "padding:9px;border:1px solid #e5e7eb;"
    $tdStyle = "padding:4px 9px;"
    $numStyle = "padding:4px 9px;text-align:right;white-space:nowrap;"
    $counts = $Compare.counts
    $overall = [string]$Compare.overall

    # Validation part. Every check gets one row; a monthly (table) check also
    # gets its month-by-month table unless the config sets "showMonths": false.
    $validationRows = @()
    $monthlySections = @()
    foreach ($check in @($Compare.checks)) {
        $format = "N2"
        $configCheck = @($Config.checks | Where-Object { [string]$_.id -eq [string]$check.id }) | Select-Object -First 1
        if ($null -eq $configCheck) { $configCheck = @($Config.derivedChecks | Where-Object { [string]$_.id -eq [string]$check.id }) | Select-Object -First 1 }
        if ($null -ne $configCheck -and -not [string]::IsNullOrWhiteSpace([string]$configCheck.format)) { $format = [string]$configCheck.format }

        $beforeText = "-"
        $afterText = "-"
        $changeText = "-"
        $noteText = [string]$check.message

        if ([string]$check.kind -eq "table") {
            $months = @($check.months)
            $showMonths = -not ($null -ne $configCheck -and $null -ne $configCheck.PSObject.Properties["showMonths"] -and -not [bool]$configCheck.showMonths)
            $newCount = @($months | Where-Object { [string]$_.message -eq "New month" }).Count
            # Before and After are totals over the months present in both snapshots,
            # so a new month or a missing month does not distort the comparison. The
            # verdict still comes from the individual months.
            $paired = @($months | Where-Object { $null -ne $_.before -and $null -ne $_.after })
            if ($paired.Count -gt 0) {
                $sumBefore = [double](($paired | ForEach-Object { [double]$_.before } | Measure-Object -Sum).Sum)
                $sumAfter = [double](($paired | ForEach-Object { [double]$_.after } | Measure-Object -Sum).Sum)
                $beforeText = Format-ValidationNumber $sumBefore $format
                $afterText = Format-ValidationNumber $sumAfter $format
                if ($sumBefore -ne 0) { $changeText = Format-ValidationPercent ((($sumAfter - $sumBefore) / $sumBefore) * 100) }
            }
            $parts = @("Total of $($paired.Count) months")
            if ($newCount -gt 0) { $parts += "$newCount new month(s) not in the total" }
            $attention = @($months | Where-Object { [string]$_.verdict -ne "PASS" })
            if ($attention.Count -gt 0) {
                # The month table may be hidden, so the months that need attention
                # are always named here.
                $details = @($attention | ForEach-Object {
                    $reason = if ($null -ne $_.percent) { Format-ValidationPercent $_.percent } else { [string]$_.message }
                    "$($_.key) $($_.verdict) ($reason)"
                })
                $noteText = ($parts -join ", ") + ". Needs attention: " + ($details -join "; ")
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$check.message)) {
                $noteText = ($parts -join ", ") + ". " + [string]$check.message
            } else {
                $noteText = ($parts -join ", ")
            }

            if ($showMonths -and $months.Count -gt 0) {
                $monthRows = @()
                foreach ($month in $months) {
                    $monthRows += "<tr>" +
                        "<td style=`"$tdStyle`">$(ConvertTo-ValidationHtml $month.key)</td>" +
                        "<td style=`"$numStyle`">$(Format-ValidationNumber $month.before $format)</td>" +
                        "<td style=`"$numStyle`">$(Format-ValidationNumber $month.after $format)</td>" +
                        "<td style=`"$numStyle`">$(Format-ValidationPercent $month.percent)</td>" +
                        "<td style=`"$tdStyle`">$(Get-ValidationVerdictText ([string]$month.verdict))</td>" +
                        "</tr>"
                }
                $monthlySections += @"
      <p style="margin:20px 0 8px;font-weight:600;">$(ConvertTo-ValidationHtml ([string]$check.label))</p>
      <table style="width:100%;border-collapse:collapse;font-size:13px;">
        <thead>
          <tr style="background:#f9fafb;text-align:left;">
            <th style="$thStyle">Month</th>
            <th style="$thStyle`text-align:right;">Before</th>
            <th style="$thStyle`text-align:right;">After</th>
            <th style="$thStyle`text-align:right;">Change</th>
            <th style="$thStyle">Result</th>
          </tr>
        </thead>
        <tbody>
          $($monthRows -join [Environment]::NewLine)
        </tbody>
      </table>
"@
            }
        } elseif ([string]$check.kind -eq "table_rows") {
            # Rows per table: totals here, and below a table of only the tables whose
            # count changed or that need attention; unchanged tables are counted.
            $tables = @($check.months)
            $beforeText = Format-ValidationNumber $check.before $format
            $afterText = Format-ValidationNumber $check.after $format
            if ($null -ne $check.percent) { $changeText = Format-ValidationPercent $check.percent }
            $changed = @($tables | Where-Object { [string]$_.verdict -ne "PASS" -or -not [string]::IsNullOrWhiteSpace([string]$_.message) -or ($null -ne $_.before -and $null -ne $_.after -and [double]$_.before -ne [double]$_.after) })
            $unchanged = $tables.Count - $changed.Count
            $parts = @("$($tables.Count) tables", "$($changed.Count) changed", "$unchanged unchanged")
            $attention = @($tables | Where-Object { [string]$_.verdict -ne "PASS" })
            $noteText = ($parts -join ", ")
            if ($attention.Count -gt 0) {
                $details = @($attention | ForEach-Object {
                    $reason = if ($null -ne $_.percent) { Format-ValidationPercent $_.percent } else { [string]$_.message }
                    "$($_.key) $($_.verdict) ($reason)"
                })
                $noteText += ". Needs attention: " + ($details -join "; ")
            }
            if ($changed.Count -gt 0) {
                $tableRows = @()
                foreach ($table in $changed) {
                    $changeCell = if ($null -ne $table.percent) { Format-ValidationPercent $table.percent } elseif ($table.message) { ConvertTo-ValidationHtml $table.message } else { "-" }
                    $tableRows += "<tr>" +
                        "<td style=`"$tdStyle`">$(ConvertTo-ValidationHtml $table.key)</td>" +
                        "<td style=`"$numStyle`">$(Format-ValidationNumber $table.before $format)</td>" +
                        "<td style=`"$numStyle`">$(Format-ValidationNumber $table.after $format)</td>" +
                        "<td style=`"$numStyle`">$changeCell</td>" +
                        "<td style=`"$tdStyle`">$(Get-ValidationVerdictText ([string]$table.verdict))</td>" +
                        "</tr>"
                }
                $unchangedLine = if ($unchanged -gt 0) { "<p style=`"margin:6px 0 0;font-size:12px;color:#6b7280;`">$unchanged other table(s) have the same number of rows as before.</p>" } else { "" }
                $monthlySections += @"
      <p style="margin:20px 0 8px;font-weight:600;">$(ConvertTo-ValidationHtml ([string]$check.label)): tables that changed</p>
      <table style="width:100%;border-collapse:collapse;font-size:13px;">
        <thead>
          <tr style="background:#f9fafb;text-align:left;">
            <th style="$thStyle">Table</th>
            <th style="$thStyle`text-align:right;">Before</th>
            <th style="$thStyle`text-align:right;">After</th>
            <th style="$thStyle`text-align:right;">Change</th>
            <th style="$thStyle">Result</th>
          </tr>
        </thead>
        <tbody>
          $($tableRows -join [Environment]::NewLine)
        </tbody>
      </table>
      $unchangedLine
"@
            }
        } elseif ([string]$check.kind -eq "scalar_date") {
            $beforeText = if ([string]::IsNullOrWhiteSpace([string]$check.before)) { "-" } else { ConvertTo-ValidationHtml ([string]$check.before) }
            $afterText = if ([string]::IsNullOrWhiteSpace([string]$check.after)) { "-" } else { ConvertTo-ValidationHtml ([string]$check.after) }
        } else {
            $beforeText = Format-ValidationNumber $check.before $format
            $afterText = Format-ValidationNumber $check.after $format
            if ($null -ne $check.percent) { $changeText = Format-ValidationPercent $check.percent }
            elseif ($null -ne $check.delta) { $changeText = Format-ValidationNumber $check.delta $format }
        }

        $note = ""
        if (-not [string]::IsNullOrWhiteSpace($noteText)) {
            $note = "<div style=`"color:#6b7280;font-size:12px;`">$(ConvertTo-ValidationHtml $noteText)</div>"
        }
        $validationRows += "<tr>" +
            "<td style=`"$tdStyle`vertical-align:top;`">$(ConvertTo-ValidationHtml $check.label)$note</td>" +
            "<td style=`"$numStyle`vertical-align:top;`">$beforeText</td>" +
            "<td style=`"$numStyle`vertical-align:top;`">$afterText</td>" +
            "<td style=`"$numStyle`vertical-align:top;`">$changeText</td>" +
            "<td style=`"$tdStyle`vertical-align:top;`">$(Get-ValidationVerdictText ([string]$check.verdict))</td>" +
            "</tr>"
    }

    $validationHeading = if (@($Compare.checks).Count -eq 0) {
        "$iconFail Validation did not run"
    } elseif ($overall -eq "FAIL") {
        "$iconFail Validation failed: $($counts.pass)/$($counts.total) checks passed"
    } elseif ($overall -eq "WARN") {
        "$iconWarn Validation passed with warnings: $($counts.pass)/$($counts.total) checks passed"
    } else {
        "$iconOk Validation passed: $($counts.pass)/$($counts.total) checks"
    }

    # Model structure: counts and the names added or removed. No result column; it
    # is for reading only. Missing on old snapshots and when the switch is off.
    $structureHtml = ""
    $structure = if ($null -ne $Compare.PSObject.Properties["structure"]) { @($Compare.structure | Where-Object { $null -ne $_ }) } else { @() }
    if ($structure.Count -gt 0) {
        $structureRows = @()
        $changeLines = @()
        $errorLines = @()
        foreach ($part in $structure) {
            $changeCell = "-"
            if ($null -ne $part.before -and $null -ne $part.after) {
                $diff = [int]$part.after - [int]$part.before
                $changeCell = if ($diff -gt 0) { "+$diff" } else { [string]$diff }
            }
            $structureRows += "<tr>" +
                "<td style=`"$tdStyle`">$(ConvertTo-ValidationHtml $part.label)</td>" +
                "<td style=`"$numStyle`">$(Format-ValidationNumber $part.before 'N0')</td>" +
                "<td style=`"$numStyle`">$(Format-ValidationNumber $part.after 'N0')</td>" +
                "<td style=`"$numStyle`">$changeCell</td>" +
                "</tr>"
            $lower = ([string]$part.label).ToLowerInvariant()
            foreach ($pair in @(@("Added", @($part.added)), @("Removed", @($part.removed)))) {
                $names = @($pair[1] | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
                if ($names.Count -eq 0) { continue }
                $shown = @($names | Select-Object -First 30 | ForEach-Object { ConvertTo-ValidationHtml $_ })
                $more = if ($names.Count -gt 30) { ", and $($names.Count - 30) more" } else { "" }
                $changeLines += "<p style=`"margin:6px 0 0;font-size:12px;line-height:1.5;`"><strong>$($pair[0]) $(ConvertTo-ValidationHtml $lower):</strong> $($shown -join ', ')$more</p>"
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$part.error)) {
                $errorLines += "<p style=`"margin:6px 0 0;font-size:12px;color:#991b1b;`">$(ConvertTo-ValidationHtml $part.label) could not be read ($(ConvertTo-ValidationHtml $part.error)).</p>"
            }
        }
        $comparable = @($structure | Where-Object { $null -ne $_.before -and $null -ne $_.after })
        $summaryLine = ""
        if ($changeLines.Count -eq 0 -and $comparable.Count -eq $structure.Count) {
            $summaryLine = "<p style=`"margin:6px 0 0;font-size:12px;color:#6b7280;`">No tables, columns, measures or relationships were added or removed.</p>"
        } elseif (@($structure | Where-Object { $null -eq $_.before -and [string]::IsNullOrWhiteSpace([string]$_.error) }).Count -gt 0) {
            $summaryLine = "<p style=`"margin:6px 0 0;font-size:12px;color:#6b7280;`">The earlier snapshot has no model structure, so only the current counts are shown.</p>"
        }
        $structureHtml = @"
      <p style="margin:20px 0 8px;font-weight:600;">Model structure</p>
      <table style="width:100%;border-collapse:collapse;font-size:13px;">
        <thead>
          <tr style="background:#f9fafb;text-align:left;">
            <th style="$thStyle">Object</th>
            <th style="$thStyle`text-align:right;">Before</th>
            <th style="$thStyle`text-align:right;">After</th>
            <th style="$thStyle`text-align:right;">Change</th>
          </tr>
        </thead>
        <tbody>
          $($structureRows -join [Environment]::NewLine)
        </tbody>
      </table>
      $($changeLines -join [Environment]::NewLine)
      $($errorLines -join [Environment]::NewLine)
      $summaryLine
"@
    }

    # One short line under the tables, written per report in the config so it can be
    # in any language. Without emailNote the email has no footnote.
    $noteHtml = ""
    if ($null -ne $Config.PSObject.Properties["emailNote"] -and -not [string]::IsNullOrWhiteSpace([string]$Config.emailNote)) {
        $noteHtml = "<p style=`"margin:16px 0 0;color:#9ca3af;font-size:11px;line-height:1.5;`">$(ConvertTo-ValidationHtml ([string]$Config.emailNote))</p>"
    }

    if ($validationRows.Count -eq 0) {
        $validationRows += "<tr><td colspan=`"5`" style=`"$tdStyle`color:#6b7280;`">No validation results.</td></tr>"
    }

    # A model without a report config is checked with the universal checks; the
    # section says so, and names the semantic model rather than a report.
    $isUniversal = $null -ne $Config.PSObject.Properties["universal"] -and [bool]$Config.universal
    $subjectLine = if ($isUniversal) {
        "<strong>Semantic model:</strong> $(ConvertTo-ValidationHtml $Config.semanticModelName) ($(ConvertTo-ValidationHtml $Config.workspaceName))<br>" +
        "<strong>Checks:</strong> universal checks for any model (no report config)<br>"
    } else {
        "<strong>Report:</strong> $(ConvertTo-ValidationHtml $Config.reportName) ($(ConvertTo-ValidationHtml $Config.workspaceName))<br>"
    }

    $html = @"
    <div style="padding:20px 24px;border-top:1px solid #e5e7eb;">
      <h3 style="margin:0 0 12px;font-size:17px;">$(ConvertTo-ValidationHtml $validationHeading)</h3>
      <p style="margin:0 0 16px;line-height:1.5;">
        $subjectLine
        <strong>Compared with:</strong> $(ConvertTo-ValidationHtml $BaselineNote)
      </p>
      <table style="width:100%;border-collapse:collapse;font-size:13px;">
        <thead>
          <tr style="background:#f9fafb;text-align:left;">
            <th style="$thStyle">Check</th>
            <th style="$thStyle`text-align:right;">Before</th>
            <th style="$thStyle`text-align:right;">After</th>
            <th style="$thStyle`text-align:right;">Change</th>
            <th style="$thStyle">Result</th>
          </tr>
        </thead>
        <tbody>
          $($validationRows -join [Environment]::NewLine)
        </tbody>
      </table>
      $($monthlySections -join [Environment]::NewLine)
      $structureHtml
      $noteHtml
    </div>
"@

    return [pscustomobject]@{
        Html = $html
        Overall = if (@($Compare.checks).Count -eq 0) { "FAIL" } else { $overall }
        Counts = $counts
    }
}

function New-ValidationEmailContent {
    # The one email of every refresh: the refresh card (every dataflow and semantic
    # model) and one validation section per checked semantic model. Pass -Compare and
    # -Config for one model, or -Sections (each {Compare, Config, BaselineNote}) for
    # several; with no section at all the email holds the refresh card only.
    param(
        [AllowNull()][pscustomobject]$Compare,
        [AllowNull()][pscustomobject]$Config,
        [AllowNull()][object]$RefreshSummary,
        [Parameter(Mandatory = $true)][string]$RunFolder,
        [Parameter(Mandatory = $true)][datetime]$StartedAt,
        [Parameter(Mandatory = $true)][datetime]$EndedAt,
        [string]$BaselineNote = "this run's pre-refresh snapshot",
        # Set when the run stopped early. The email then says so instead of
        # pretending to be a normal report.
        [string]$FatalError = "",
        [AllowNull()][object[]]$Sections,
        # Subject name; defaults to the config's report name.
        [string]$Title = ""
    )

    $refreshItems = @()
    if ($null -ne $RefreshSummary) {
        foreach ($item in @($RefreshSummary.Dataflows)) {
            $refreshItems += [pscustomobject]@{ Type = "Dataflow"; Name = $item.name; WorkspaceName = $item.workspaceName; Status = $item.status; Error = $item.error; CompletedAt = $item.completedAt }
        }
        foreach ($item in @($RefreshSummary.SemanticModels)) {
            $refreshItems += [pscustomobject]@{ Type = "Semantic model"; Name = $item.name; WorkspaceName = $item.workspaceName; Status = $item.status; Error = $item.error; CompletedAt = $item.completedAt }
        }
    }
    $successStatuses = @("Success", "Succeeded", "Completed")
    $refreshFailed = $null -eq $RefreshSummary
    if ($null -ne $RefreshSummary) {
        $refreshFailed = @($refreshItems | Where-Object { $successStatuses -notcontains [string]$_.Status }).Count -gt 0
    }

    $sectionInputs = if ($null -ne $Sections) {
        @($Sections | Where-Object { $null -ne $_ })
    } elseif ($null -ne $Compare -and $null -ne $Config) {
        @([pscustomobject]@{ Compare = $Compare; Config = $Config; BaselineNote = $BaselineNote })
    } else { @() }
    $rendered = @(foreach ($section in $sectionInputs) {
        $note = if (-not [string]::IsNullOrWhiteSpace([string]$section.BaselineNote)) { [string]$section.BaselineNote } else { $BaselineNote }
        Get-ValidationSectionHtml -Compare $section.Compare -Config $section.Config -BaselineNote $note
    })

    $iconOk = [string][char]0x2705
    $iconWarn = [string][char]0x26A0
    $iconFail = [string][char]0x274C

    $overall = Get-ValidationWorstVerdict @($rendered | ForEach-Object { [string]$_.Overall })
    $pass = 0; $total = 0
    foreach ($section in $rendered) {
        if ($null -ne $section.Counts) { $pass += [int]$section.Counts.pass; $total += [int]$section.Counts.total }
    }
    $icon = $iconOk
    if ($overall -eq "FAIL" -or $refreshFailed -or $FatalError) { $icon = $iconFail } elseif ($overall -eq "WARN") { $icon = $iconWarn }
    $refreshText = if ($refreshFailed) { "refresh failed" } else { "refresh OK" }
    $name = if (-not [string]::IsNullOrWhiteSpace($Title)) { $Title } elseif ($null -ne $Config) { [string]$Config.reportName } else { "Refresh" }
    $subject = if ($FatalError) {
        "$icon ${name}: run did not complete"
    } elseif ($rendered.Count -eq 0) {
        "$icon ${name}: $refreshText"
    } else {
        "$icon ${name}: $refreshText, $pass/$total checks passed"
    }

    # Refresh part: one row per dataflow and semantic model, as in every chained run.
    $refreshHeading = if ($FatalError) {
        "$iconFail Run did not complete"
    } elseif (@($refreshItems).Count -eq 0) {
        "$iconFail Refresh did not complete"
    } elseif ($refreshFailed) {
        "$iconWarn Refresh completed with errors"
    } else {
        "$iconOk Refresh completed: $(@($refreshItems).Count) items"
    }

    $thStyle = "padding:9px;border:1px solid #e5e7eb;"

    $refreshRows = @()
    foreach ($item in $refreshItems) {
        $status = [string]$item.Status
        $statusColor = if ($successStatuses -contains $status) { "#15803d" } elseif ($status -eq "Skipped") { "#a16207" } else { "#b91c1c" }
        $errorText = if ([string]::IsNullOrWhiteSpace([string]$item.Error)) { "-" } else { ConvertTo-ValidationHtml $item.Error }
        $refreshRows += "<tr>" +
            "<td>$(ConvertTo-ValidationHtml $item.Type)</td>" +
            "<td>$(ConvertTo-ValidationHtml $item.Name)</td>" +
            "<td>$(ConvertTo-ValidationHtml $item.WorkspaceName)</td>" +
            "<td style=`"font-weight:600;color:$statusColor`">$(ConvertTo-ValidationHtml $status)</td>" +
            "<td>$(Format-ValidationCompletedAt $item.CompletedAt)</td>" +
            "<td>$errorText</td>" +
            "</tr>"
    }

    $duration = $EndedAt - $StartedAt
    $durationText = if ($duration.TotalHours -ge 1) {
        "{0:00}:{1:00}:{2:00}" -f [math]::Floor($duration.TotalHours), $duration.Minutes, $duration.Seconds
    } else {
        "{0:00}:{1:00}" -f [math]::Floor($duration.TotalMinutes), $duration.Seconds
    }

    $bannerStyle = "margin:0 0 16px;padding:10px 12px;border:1px solid #fecaca;background:#fef2f2;border-radius:6px;color:#991b1b;font-size:13px;line-height:1.5;"
    $banner = ""
    if ($FatalError) {
        $banner = "<div style=`"$bannerStyle`">The run stopped before it finished: $(ConvertTo-ValidationHtml $FatalError)</div>"
    } elseif ($refreshFailed) {
        $banner = "<div style=`"$bannerStyle`">The refresh did not complete successfully, so the post-refresh snapshot may reflect unchanged data.</div>"
    }

    $refreshBlock = if (@($refreshItems).Count -gt 0) {
        @"
      <table style="width:100%;border-collapse:collapse;font-size:13px;">
        <thead>
          <tr style="background:#f9fafb;text-align:left;">
            <th style="$thStyle">Type</th>
            <th style="$thStyle">Item</th>
            <th style="$thStyle">Workspace</th>
            <th style="$thStyle">Status</th>
            <th style="$thStyle">Completed</th>
            <th style="$thStyle">Error</th>
          </tr>
        </thead>
        <tbody>
          $($refreshRows -join [Environment]::NewLine)
        </tbody>
      </table>
"@
    } else {
        "<p style=`"margin:0;color:#991b1b;`">The refresh summary is not available.</p>"
    }

    $htmlBody = @"
<!doctype html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family:Segoe UI,Arial,sans-serif;color:#1f2937;margin:0;padding:24px;background:#f3f4f6;">
  <div style="max-width:900px;margin:0 auto;background:#ffffff;border:1px solid #e5e7eb;border-radius:10px;overflow:hidden;">
    <div style="padding:20px 24px;background:#111827;color:#ffffff;">
      <h2 style="margin:0;font-size:20px;">$(ConvertTo-ValidationHtml $refreshHeading)</h2>
    </div>
    <div style="padding:20px 24px;">
      $banner
      <p style="margin:0 0 16px;line-height:1.5;">
        <strong>Started:</strong> $(ConvertTo-ValidationHtml $StartedAt.ToString("yyyy-MM-dd HH:mm:ss zzz"))<br>
        <strong>Finished:</strong> $(ConvertTo-ValidationHtml $EndedAt.ToString("yyyy-MM-dd HH:mm:ss zzz"))<br>
        <strong>Duration:</strong> $(ConvertTo-ValidationHtml $durationText)
      </p>
      $refreshBlock
    </div>
$(($rendered | ForEach-Object { $_.Html }) -join [Environment]::NewLine)
  </div>
</body>
</html>
"@

    return [pscustomobject]@{
        Subject = $subject
        HtmlBody = $htmlBody
        Overall = if ($rendered.Count -eq 0) { "" } else { $overall }
        RefreshFailed = $refreshFailed
    }
}

function Add-ValidationHistory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][pscustomobject]$Compare,
        [Parameter(Mandatory = $true)][string]$RunFolder,
        [string]$WorkspaceName = "",
        [string]$ReportName = ""
    )

    $lines = @()
    if (-not (Test-Path -LiteralPath $Path)) {
        $lines += 'timestamp,workspace,report,runFolder,check,verdict,before,after,percent,message'
    }
    $stamp = (Get-Date).ToString("o")
    foreach ($check in @($Compare.checks)) {
        $before = if ($null -ne $check.before) { [string]$check.before } else { "" }
        $after = if ($null -ne $check.after) { [string]$check.after } else { "" }
        $percent = if ($null -ne $check.percent) { [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.00}", [double]$check.percent) } else { "" }
        $fields = @($stamp, $WorkspaceName, $ReportName, $RunFolder, [string]$check.id, [string]$check.verdict, $before, $after, $percent, [string]$check.message)
        $quoted = foreach ($field in $fields) {
            $text = [string]$field
            if ($text -match '[",\r\n]') { '"' + ($text -replace '"', '""') + '"' } else { $text }
        }
        $lines += ($quoted -join ',')
    }

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    [System.IO.File]::AppendAllText($Path, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
}
