# Rebind building blocks: request and profile validation, the operation lock, atomic
# status writes, Scan, Apply and verification.
#
# server.ps1 dot-sources this file for request handling; runtime\Invoke-RebindRun.ps1
# dot-sources it to run one Scan or Apply in its own process; _rebind-tests.ps1
# exercises it against disposable folders. Nothing here contacts Power BI.
#
# Ownership model. rebind.lock is held open (write access, read sharing) by whichever
# process may change rebind-status.json: a worker for its whole run, or the server for
# the few milliseconds of a cancel or a startup reconcile. Windows closes the handle
# when the process ends, so a crashed worker frees the lock and a live one cannot be
# overruled by a restarted server. Every status record names the operation that wrote
# it (operationId), and status files are replaced atomically, never rewritten in place.
#
# Windows PowerShell 5.1. Keep this file ASCII-only.

$script:RebindMappingTypes = @("Workspace", "Dataflow", "Dataset")
$script:RebindProfileLimits = @{ MaxProfiles = 500; MaxMappings = 200; MaxName = 200; MaxPath = 4096; MaxId = 200 }

# ============================================================
# Small helpers
# ============================================================
function Get-RebindSafeText {
    # One line, length-capped text for logs and error responses.
    param([AllowNull()][object]$Value, [int]$MaxLength = 400)

    if ($null -eq $Value) { return "" }
    $text = ([string]$Value) -replace '[\r\n\t]+', ' '
    $text = $text.Trim()
    if ($text.Length -gt $MaxLength) { $text = $text.Substring(0, $MaxLength) + "..." }
    return $text
}

function ConvertTo-RebindJson {
    param([AllowNull()][object]$Value)
    return ConvertTo-Json -InputObject $Value -Depth 20 -Compress
}

function Set-RebindStateValue {
    # Sets a field on a status record read from JSON, adding it when an older record lacks it.
    param([Parameter(Mandatory = $true)][object]$State, [Parameter(Mandatory = $true)][string]$Name, [AllowNull()][object]$Value)
    $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function ConvertTo-RebindJsonArray {
    # Windows PowerShell unrolls one-element arrays; build the array text explicitly.
    param([AllowNull()][object[]]$Items)

    $parts = @()
    foreach ($item in @($Items)) { $parts += (ConvertTo-RebindJson $item) }
    return "[" + ($parts -join ",") + "]"
}

function Get-RebindHash {
    param([byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
    return ([BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
}

function Join-RebindPath {
    # Literal path join: no wildcard or provider interpretation.
    param([string]$Root, [string]$RelativePath)
    return [System.IO.Path]::Combine($Root, $RelativePath)
}

function Get-RebindRelativePath {
    param([string]$Root, [string]$FullName)

    $rootText = $Root.TrimEnd('\', '/')
    if ($FullName.Length -gt $rootText.Length -and $FullName.StartsWith($rootText, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $FullName.Substring($rootText.Length).TrimStart('\', '/')
    }
    return $FullName
}

# ============================================================
# Atomic files
# ============================================================
function Write-RebindFileAtomic {
    # Writes a sibling temporary file, then swaps it in with File.Replace (or Move when
    # the target does not exist yet). A failure leaves the previous file untouched.
    # Sharing violations are retried briefly, because readers may hold the file.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [int]$Attempts = 25
    )

    $ErrorActionPreference = "Stop"
    $directory = [System.IO.Path]::GetDirectoryName($Path)
    $name = [System.IO.Path]::GetFileName($Path)
    $temp = [System.IO.Path]::Combine($directory, "." + $name + "." + [Guid]::NewGuid().ToString("N") + ".rebind-tmp")
    try {
        [System.IO.File]::WriteAllBytes($temp, $Bytes)
        $lastError = $null
        for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
            try {
                if ([System.IO.File]::Exists($Path)) {
                    # [NullString]::Value: PowerShell would pass $null as "" (no backup wanted).
                    [System.IO.File]::Replace($temp, $Path, [NullString]::Value)
                } else {
                    [System.IO.File]::Move($temp, $Path)
                }
                return
            } catch {
                $lastError = $_.Exception
                if ($lastError -is [System.Management.Automation.MethodInvocationException] -and $lastError.InnerException) {
                    $lastError = $lastError.InnerException
                }
                Start-Sleep -Milliseconds 40
            }
        }
        throw $lastError
    } finally {
        if ([System.IO.File]::Exists($temp)) {
            try { [System.IO.File]::Delete($temp) } catch { }
        }
    }
}

function Write-RebindJsonAtomic {
    # UTF-8 without a byte order mark.
    param([Parameter(Mandatory = $true)][string]$Path, [AllowNull()][object]$Value, [string]$Json)

    if (-not $PSBoundParameters.ContainsKey("Json")) { $Json = ConvertTo-RebindJson $Value }
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Json)
    Write-RebindFileAtomic -Path $Path -Bytes $bytes
}

function Read-RebindSharedText {
    # Reads text while allowing a concurrent atomic replace of the same file.
    param([Parameter(Mandatory = $true)][string]$Path)

    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
        $reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding($false)), $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

function Read-RebindStatus {
    # Exists = $false: no status file. Readable = $false: present but not a JSON object
    # (after a few short retries). An unreadable status is never treated as "idle".
    param([Parameter(Mandatory = $true)][string]$Path, [int]$Attempts = 5)

    $ErrorActionPreference = "Stop"
    if (-not [System.IO.File]::Exists($Path)) {
        return [pscustomobject]@{ Exists = $false; Readable = $true; State = $null; Error = "" }
    }
    $lastError = ""
    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        try {
            $text = Read-RebindSharedText -Path $Path
            if ([string]::IsNullOrWhiteSpace($text)) { throw "The status file is empty" }
            $state = ConvertFrom-Json -InputObject $text -ErrorAction Stop
            if ($state -isnot [System.Management.Automation.PSCustomObject]) { throw "The status file does not hold a JSON object" }
            return [pscustomobject]@{ Exists = $true; Readable = $true; State = $state; Error = "" }
        } catch {
            $lastError = Get-RebindSafeText $_.Exception.Message
            if ($attempt -lt $Attempts - 1) { Start-Sleep -Milliseconds 40 }
        }
    }
    if (-not [System.IO.File]::Exists($Path)) {
        return [pscustomobject]@{ Exists = $false; Readable = $true; State = $null; Error = "" }
    }
    return [pscustomobject]@{ Exists = $true; Readable = $false; State = $null; Error = $lastError }
}

# ============================================================
# Operation lock
# ============================================================
function Enter-RebindLock {
    # Returns the open lock stream, or $null while another process holds it. The
    # caller disposes the stream to release the lock; process exit releases it too.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$OperationId = "",
        [string]$Kind = "",
        [int]$Attempts = 1,
        [int]$RetryMilliseconds = 100,
        [switch]$NoRecord
    )

    $ErrorActionPreference = "Stop"
    $directory = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($directory)) { [System.IO.Directory]::CreateDirectory($directory) | Out-Null }
    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
        } catch [System.IO.IOException] {
            if ($attempt -lt $Attempts - 1) { Start-Sleep -Milliseconds $RetryMilliseconds }
            continue
        }
        if (-not $NoRecord) {
            try {
                $record = [ordered]@{ operationId = $OperationId; kind = $Kind; pid = $PID; acquiredAt = (Get-Date).ToUniversalTime().ToString("o") }
                $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-RebindJson $record))
                $stream.SetLength(0)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
            } catch { }
        }
        return $stream
    }
    return $null
}

function Test-RebindLockHeld {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = Enter-RebindLock -Path $Path -NoRecord
    if ($null -eq $stream) { return $true }
    $stream.Dispose()
    return $false
}

# ============================================================
# Target files and text
# ============================================================
function Test-RebindTargetPath {
    # .tmdl and .json files outside any .pbi folder (local Power BI Desktop cache).
    param([string]$RelativePath)

    $extension = [System.IO.Path]::GetExtension($RelativePath)
    if ($extension -ne ".tmdl" -and $extension -ne ".json") { return $false }
    return -not (("\" + $RelativePath.Replace('/', '\')) -match '\\\.pbi\\')
}

function Get-RebindTargetFiles {
    # Literal, recursive enumeration. Folders that cannot be listed are returned as
    # errors instead of being skipped silently.
    param([Parameter(Mandatory = $true)][string]$Root)

    $enumErrors = @()
    $items = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue -ErrorVariable enumErrors)
    $files = @()
    foreach ($item in $items) {
        $relative = Get-RebindRelativePath -Root $Root -FullName $item.FullName
        if (Test-RebindTargetPath $relative) {
            $files += [pscustomobject]@{ FullName = $item.FullName; RelativePath = $relative }
        }
    }
    $errors = @()
    foreach ($enumError in @($enumErrors)) {
        $target = if ($enumError.TargetObject) { Get-RebindRelativePath -Root $Root -FullName ([string]$enumError.TargetObject) } else { "" }
        $errors += [pscustomobject]@{ file = $target; reason = "Could not list: " + (Get-RebindSafeText $enumError.Exception.Message) }
    }
    return [pscustomobject]@{
        Files = @($files | Sort-Object RelativePath)
        Errors = @($errors)
    }
}

function Read-RebindTextFile {
    # Decodes UTF-8 (with or without a byte order mark) and UTF-16 with a byte order
    # mark. Anything else throws, so a file is never rewritten in a guessed encoding.
    param([Parameter(Mandatory = $true)][string]$Path)

    $ErrorActionPreference = "Stop"
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object System.Text.UTF8Encoding($true, $true); $name = "utf-8-bom"; $offset = 3
    } elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) {
        throw "UTF-32 files are not supported"
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = New-Object System.Text.UnicodeEncoding($false, $true, $true); $name = "utf-16le"; $offset = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = New-Object System.Text.UnicodeEncoding($true, $true, $true); $name = "utf-16be"; $offset = 2
    } else {
        $encoding = New-Object System.Text.UTF8Encoding($false, $true); $name = "utf-8"
    }
    try {
        $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    } catch {
        throw "Unsupported text encoding (not valid $name)"
    }
    return [pscustomobject]@{
        Text = $text
        Encoding = $encoding
        EncodingName = $name
        Hash = Get-RebindHash $bytes
        Length = $bytes.Length
    }
}

function ConvertTo-RebindEncodedBytes {
    # Same encoding and the same byte order mark (or none) as the file that was read.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text, [Parameter(Mandatory = $true)][System.Text.Encoding]$Encoding)

    $preamble = $Encoding.GetPreamble()
    $body = $Encoding.GetBytes($Text)
    $result = New-Object byte[] ($preamble.Length + $body.Length)
    [Array]::Copy($preamble, 0, $result, 0, $preamble.Length)
    [Array]::Copy($body, 0, $result, $preamble.Length, $body.Length)
    return ,$result
}

function Get-RebindLineStarts {
    param([AllowEmptyString()][string]$Text)

    $starts = New-Object System.Collections.Generic.List[int]
    $starts.Add(0)
    $index = $Text.IndexOf("`n")
    while ($index -ge 0) {
        $starts.Add($index + 1)
        $index = $Text.IndexOf("`n", $index + 1)
    }
    return ,$starts.ToArray()
}

function Find-RebindGuidLines {
    # Every case-insensitive occurrence of a GUID: the total count and each distinct
    # line (1-based number and trimmed text).
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory = $true)][string]$Guid)

    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $found = [regex]::Matches($Text, [regex]::Escape($Guid), $options)
    $lines = New-Object System.Collections.ArrayList
    if ($found.Count -eq 0) { return [pscustomobject]@{ Count = 0; Lines = @() } }

    $starts = Get-RebindLineStarts $Text
    $seen = @{}
    foreach ($match in $found) {
        $position = [Array]::BinarySearch($starts, [int]$match.Index)
        $lineIndex = if ($position -ge 0) { $position } else { (-bnot $position) - 1 }
        if ($seen.ContainsKey($lineIndex)) { continue }
        $seen[$lineIndex] = $true
        $start = $starts[$lineIndex]
        $end = if ($lineIndex + 1 -lt $starts.Length) { $starts[$lineIndex + 1] - 1 } else { $Text.Length }
        $lineText = $Text.Substring($start, [Math]::Max(0, $end - $start)).TrimEnd("`r").Trim()
        [void]$lines.Add([pscustomobject]@{ line = $lineIndex + 1; text = (Get-RebindSafeText $lineText 300) })
    }
    return [pscustomobject]@{ Count = $found.Count; Lines = @($lines) }
}

# ============================================================
# Status writer used by the worker
# ============================================================
function New-RebindStatusWriter {
    # Path may be empty (tests): log lines then stay in memory only.
    param([string]$Path, [System.Collections.IDictionary]$State)

    if ($null -eq $State) { $State = [ordered]@{} }
    if (-not $State.Contains("logs")) { $State["logs"] = New-Object System.Collections.ArrayList }
    return @{ Path = $Path; State = $State }
}

function Save-RebindStatus {
    param([Parameter(Mandatory = $true)][hashtable]$Writer)

    if (-not $Writer.Path) { return }
    $Writer.State["updatedAt"] = (Get-Date).ToUniversalTime().ToString("o")
    Write-RebindJsonAtomic -Path $Writer.Path -Value $Writer.State
}

function Add-RebindLog {
    param([hashtable]$Writer, [string]$Text)

    if ($null -eq $Writer) { return }
    [void]$Writer.State["logs"].Add([ordered]@{ time = (Get-Date -Format "HH:mm:ss"); text = $Text })
    try { Save-RebindStatus $Writer } catch { }
}

function Set-RebindPhase {
    param([hashtable]$Writer, [string]$Phase)

    if ($null -eq $Writer) { return }
    $Writer.State["phase"] = $Phase
    $Writer.State["running"] = -not ($Phase -in @("scan_done", "done", "failed", "cancelled", "idle"))
    Save-RebindStatus $Writer
}

# ============================================================
# Requests
# ============================================================
function Get-RebindRequest {
    param($Body)

    if ($null -eq $Body -or $Body -isnot [System.Management.Automation.PSCustomObject]) {
        return [pscustomobject]@{ Ok = $false; Error = "The request must be a JSON object" }
    }
    $rawPath = [string]$Body.ReportPath
    if ([string]::IsNullOrWhiteSpace($rawPath)) {
        return [pscustomobject]@{ Ok = $false; Error = "Report folder path is required" }
    }

    try {
        $resolvedPath = (Resolve-Path -LiteralPath $rawPath -ErrorAction Stop).ProviderPath
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

    $rawMappings = @($Body.Mappings | Where-Object { $null -ne $_ })
    if ($rawMappings.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Error = "At least one GUID mapping is required" }
    }

    $normalized = @()
    $oldGuids = @{}
    foreach ($mapping in $rawMappings) {
        $type = [string]$mapping.Type
        $oldText = ([string]$mapping.OldGuid).Trim()
        $newText = ([string]$mapping.NewGuid).Trim()
        $oldGuid = [Guid]::Empty
        $newGuid = [Guid]::Empty

        if ($script:RebindMappingTypes -notcontains $type) {
            return [pscustomobject]@{ Ok = $false; Error = "Unsupported mapping type: $(Get-RebindSafeText $type 60)" }
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
    $signature = Get-RebindHash ([System.Text.Encoding]::UTF8.GetBytes($signatureInput))

    return [pscustomobject]@{
        Ok = $true
        Error = ""
        ReportPath = $resolvedPath
        Mappings = $normalized
        Signature = $signature
    }
}

function Read-RebindRequestText {
    # Reads at most MaxBytes from a request body. Larger bodies are refused unread.
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [long]$DeclaredLength = -1,
        [int]$MaxBytes = 1048576
    )

    if ($DeclaredLength -gt $MaxBytes) {
        return [pscustomobject]@{ Ok = $false; StatusCode = 413; Error = "The request body is too large"; Text = "" }
    }
    $buffer = New-Object byte[] 65536
    $memory = New-Object System.IO.MemoryStream
    try {
        while (($read = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $memory.Write($buffer, 0, $read)
            if ($memory.Length -gt $MaxBytes) {
                return [pscustomobject]@{ Ok = $false; StatusCode = 413; Error = "The request body is too large"; Text = "" }
            }
        }
        $text = (New-Object System.Text.UTF8Encoding($false)).GetString($memory.ToArray())
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
        return [pscustomobject]@{ Ok = $true; StatusCode = 200; Error = ""; Text = $text }
    } finally {
        $memory.Dispose()
    }
}

function ConvertFrom-RebindRequestJson {
    # A JSON object, or an empty body when AllowEmpty is set.
    param([AllowNull()][AllowEmptyString()][string]$Text, [switch]$AllowEmpty)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        if ($AllowEmpty) { return [pscustomobject]@{ Ok = $true; Value = $null; Error = "" } }
        return [pscustomobject]@{ Ok = $false; Value = $null; Error = "The request body is empty" }
    }
    try {
        $value = ConvertFrom-Json -InputObject $Text -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Ok = $false; Value = $null; Error = "The request body is not valid JSON" }
    }
    if ($value -isnot [System.Management.Automation.PSCustomObject]) {
        return [pscustomobject]@{ Ok = $false; Value = $null; Error = "The request body must be a JSON object" }
    }
    return [pscustomobject]@{ Ok = $true; Value = $value; Error = "" }
}

# ============================================================
# Saved profiles
# ============================================================
function Test-RebindPlainText {
    param([AllowNull()][object]$Value, [int]$MaxLength)

    if ($null -eq $Value) { return $true }
    if ($Value -isnot [string]) { return $false }
    if ($Value.Length -gt $MaxLength) { return $false }
    return -not ($Value -match '[\x00-\x1F\x7F]')
}

function ConvertTo-RebindProfileCollection {
    # Validates the complete collection the page wants to save. Accepted rows keep
    # only type, fromId and toId: row IDs are page-internal and are never stored.
    # Unfinished drafts (empty folder, partial or invalid GUID text) are allowed.
    param([AllowNull()][AllowEmptyString()][string]$Json)

    $limits = $script:RebindProfileLimits
    $fail = { param($message) [pscustomobject]@{ Ok = $false; Error = $message; Profiles = @() } }
    if ([string]::IsNullOrWhiteSpace($Json)) { return & $fail "The profile list is empty" }
    try {
        $data = ConvertFrom-Json -InputObject $Json -ErrorAction Stop
    } catch {
        return & $fail "The profile list is not valid JSON"
    }
    if ($null -eq $data -and $Json.Trim() -match '^\[\s*\]$') { $data = @() }
    if ($null -eq $data -or $data -isnot [System.Array]) { return & $fail "The profile list must be a JSON array" }
    if ($data.Count -gt $limits.MaxProfiles) { return & $fail "Too many profiles (limit $($limits.MaxProfiles))" }

    $profiles = @()
    $names = @{}
    for ($i = 0; $i -lt $data.Count; $i++) {
        $item = $data[$i]
        $label = "Profile $($i + 1)"
        if ($item -isnot [System.Management.Automation.PSCustomObject]) { return & $fail "$label is not an object" }
        foreach ($property in $item.PSObject.Properties) {
            if ($property.Name -notin @("name", "reportPath", "mappings")) {
                return & $fail "$label has an unsupported field: $(Get-RebindSafeText $property.Name 60)"
            }
        }
        if ($item.name -isnot [string] -or [string]::IsNullOrWhiteSpace($item.name)) { return & $fail "$label needs a name" }
        $name = $item.name.Trim()
        if (-not (Test-RebindPlainText $name $limits.MaxName)) { return & $fail "$label has a name that is too long or contains control characters" }
        $label = "Profile `"$(Get-RebindSafeText $name 80)`""
        if ($names.ContainsKey($name)) { return & $fail "$label appears more than once" }
        $names[$name] = $true

        $reportPath = $item.reportPath
        if ($null -eq $reportPath) { $reportPath = "" }
        if (-not (Test-RebindPlainText $reportPath $limits.MaxPath)) { return & $fail "$label has a folder path that is not plain text" }

        $rawMappings = $item.mappings
        if ($null -eq $rawMappings) { $rawMappings = @() }
        if ($rawMappings -isnot [System.Array]) { return & $fail "$label has mappings that are not a list" }
        if ($rawMappings.Count -gt $limits.MaxMappings) { return & $fail "$label has too many mappings (limit $($limits.MaxMappings))" }
        $rows = @()
        for ($j = 0; $j -lt $rawMappings.Count; $j++) {
            $row = $rawMappings[$j]
            $rowLabel = "$label mapping $($j + 1)"
            if ($row -isnot [System.Management.Automation.PSCustomObject]) { return & $fail "$rowLabel is not an object" }
            foreach ($property in $row.PSObject.Properties) {
                if ($property.Name -notin @("id", "type", "fromId", "toId")) {
                    return & $fail "$rowLabel has an unsupported field: $(Get-RebindSafeText $property.Name 60)"
                }
            }
            $type = [string]$row.type
            if ($script:RebindMappingTypes -cnotcontains $type) { return & $fail "$rowLabel has an unsupported type" }
            foreach ($field in @("fromId", "toId")) {
                if (-not (Test-RebindPlainText $row.$field $limits.MaxId)) { return & $fail "$rowLabel has a $field value that is not plain text" }
            }
            $rows += [ordered]@{
                type = $type
                fromId = if ($null -eq $row.fromId) { "" } else { [string]$row.fromId }
                toId = if ($null -eq $row.toId) { "" } else { [string]$row.toId }
            }
        }
        $profiles += [ordered]@{ name = $name; reportPath = [string]$reportPath; mappings = @($rows) }
    }
    return [pscustomobject]@{ Ok = $true; Error = ""; Profiles = @($profiles) }
}

function ConvertTo-RebindProfileJson {
    param([AllowNull()][object[]]$Profiles)

    $parts = @()
    foreach ($profile in @($Profiles)) {
        $rows = ConvertTo-RebindJsonArray @($profile.mappings)
        $parts += "{`"name`":" + (ConvertTo-RebindJson ([string]$profile.name)) + ",`"reportPath`":" + (ConvertTo-RebindJson ([string]$profile.reportPath)) + ",`"mappings`":" + $rows + "}"
    }
    return "[" + ($parts -join ",") + "]"
}

function Read-RebindProfileFile {
    # Returns the saved profiles as JSON array text. A file that cannot be parsed is
    # reported, never replaced by an empty list.
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.File]::Exists($Path)) { return [pscustomobject]@{ Ok = $true; Json = "[]"; Error = "" } }
    try {
        $text = Read-RebindSharedText -Path $Path
        if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{ Ok = $true; Json = "[]"; Error = "" } }
        $data = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Ok = $false; Json = ""; Error = "rebind-profiles.json could not be read: $(Get-RebindSafeText $_.Exception.Message 200)" }
    }
    if ($data -is [System.Management.Automation.PSCustomObject]) { $data = @($data) }
    if ($data -isnot [System.Array]) {
        return [pscustomobject]@{ Ok = $false; Json = ""; Error = "rebind-profiles.json does not hold a list of profiles" }
    }
    return [pscustomobject]@{ Ok = $true; Json = (ConvertTo-RebindJsonArray $data); Error = "" }
}

function Save-RebindProfileFile {
    # Validates first, then replaces the file atomically. Returns StatusCode and Body.
    param([Parameter(Mandatory = $true)][string]$Path, [AllowNull()][AllowEmptyString()][string]$Json)

    $existing = Read-RebindProfileFile -Path $Path
    if (-not $existing.Ok) {
        return @{ StatusCode = 409; Body = @{ ok = $false; error = "$($existing.Error). It was left unchanged; fix or move it aside before saving." } }
    }
    $collection = ConvertTo-RebindProfileCollection -Json $Json
    if (-not $collection.Ok) {
        return @{ StatusCode = 400; Body = @{ ok = $false; error = "Profiles were not saved: $($collection.Error)" } }
    }
    try {
        Write-RebindJsonAtomic -Path $Path -Json (ConvertTo-RebindProfileJson $collection.Profiles)
    } catch {
        return @{ StatusCode = 500; Body = @{ ok = $false; error = "Profiles were not saved: $(Get-RebindSafeText $_.Exception.Message 200)" } }
    }
    return @{ StatusCode = 200; Body = @{ ok = $true; count = @($collection.Profiles).Count } }
}

# ============================================================
# Scan
# ============================================================
function Invoke-RebindScan {
    # Read-only. Returns the results the page shows, plus the manifest Apply is bound
    # to: every file with an old GUID, with its hash, size and encoding.
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object[]]$Mappings,
        [hashtable]$Writer
    )

    $ErrorActionPreference = "Stop"
    Add-RebindLog $Writer "=== SCAN ==="
    Add-RebindLog $Writer "Path: $Root"
    Add-RebindLog $Writer "Mappings: $($Mappings.Count)"

    $hasReport = @(Get-ChildItem -LiteralPath $Root -Filter "*.Report" -Directory -ErrorAction SilentlyContinue).Count -gt 0
    $hasModel = @(Get-ChildItem -LiteralPath $Root -Filter "*.SemanticModel" -Directory -ErrorAction SilentlyContinue).Count -gt 0
    $hasPbip = @(Get-ChildItem -LiteralPath $Root -Filter "*.pbip" -File -ErrorAction SilentlyContinue).Count -gt 0
    Add-RebindLog $Writer "PBIP structure: Report=$hasReport, SemanticModel=$hasModel, .pbip=$hasPbip"

    $listing = Get-RebindTargetFiles -Root $Root
    Add-RebindLog $Writer "Target files found: $($listing.Files.Count)"

    $unreadable = New-Object System.Collections.ArrayList
    foreach ($listError in $listing.Errors) {
        [void]$unreadable.Add([ordered]@{ file = $listError.file; reason = $listError.reason })
    }

    $scanMappings = @()
    foreach ($m in $Mappings) {
        $scanMappings += [ordered]@{
            type = $m.Type; oldGuid = $m.OldGuid; newGuid = $m.NewGuid
            totalOccurrences = 0
            occurrences = New-Object System.Collections.ArrayList
            ambiguous = New-Object System.Collections.ArrayList
        }
    }
    $newGuidPresence = New-Object System.Collections.ArrayList
    $manifest = New-Object System.Collections.ArrayList

    foreach ($file in $listing.Files) {
        $relative = $file.RelativePath
        try {
            $content = Read-RebindTextFile -Path $file.FullName
        } catch {
            [void]$unreadable.Add([ordered]@{ file = $relative; reason = Get-RebindSafeText $_.Exception.Message 200 })
            continue
        }
        $fileHits = 0
        foreach ($entry in $scanMappings) {
            $old = Find-RebindGuidLines -Text $content.Text -Guid $entry.oldGuid
            if ($old.Count -gt 0) {
                $context = @($old.Lines | Select-Object -First 2 | ForEach-Object { "${relative}:$($_.line): $($_.text)" })
                [void]$entry.occurrences.Add([ordered]@{
                    file = $relative
                    count = $old.Count
                    lines = @($old.Lines | ForEach-Object { $_.line })
                    context = $context
                })
                $entry.totalOccurrences += $old.Count
                $fileHits += $old.Count
            }
            $new = Find-RebindGuidLines -Text $content.Text -Guid $entry.newGuid
            if ($new.Count -gt 0) {
                [void]$newGuidPresence.Add([ordered]@{ guid = $entry.newGuid; file = $relative; line = $new.Lines[0].line; text = $new.Lines[0].text })
            }
        }
        if ($fileHits -gt 0) {
            [void]$manifest.Add([ordered]@{ file = $relative; hash = $content.Hash; length = $content.Length; encoding = $content.EncodingName })
        }
    }

    foreach ($entry in $scanMappings) {
        Add-RebindLog $Writer "---"
        Add-RebindLog $Writer "Scan $($entry.type): $($entry.oldGuid.Substring(0, 8))..."
        Add-RebindLog $Writer "  $($entry.totalOccurrences) hit(s) in $($entry.occurrences.Count) file(s)"
        foreach ($occurrence in $entry.occurrences) {
            Add-RebindLog $Writer "  $($occurrence.file): $($occurrence.count) hit(s)"
            foreach ($line in $occurrence.context) { Add-RebindLog $Writer "    $line" }
        }
        $present = @($newGuidPresence | Where-Object { $_.guid -eq $entry.newGuid })
        if ($present.Count -gt 0) {
            Add-RebindLog $Writer "  WARN: new GUID $($entry.newGuid.Substring(0, 8))... already in:"
            foreach ($item in $present) { Add-RebindLog $Writer "    $($item.file):$($item.line): $($item.text)" }
        }
    }

    Add-RebindLog $Writer "---"
    Add-RebindLog $Writer "Ambiguity check..."
    foreach ($entry in $scanMappings) {
        foreach ($occurrence in $entry.occurrences) {
            if ([System.IO.Path]::GetExtension($occurrence.file) -eq ".json" -and $occurrence.file -notmatch 'Report') {
                Add-RebindLog $Writer "  WARN: $($entry.oldGuid.Substring(0, 8))... in non-Report JSON: $($occurrence.file)"
                [void]$entry.ambiguous.Add([ordered]@{ file = $occurrence.file; reason = "Non-report JSON file" })
            }
        }
    }
    foreach ($item in $unreadable) {
        Add-RebindLog $Writer "  WARN: could not inspect $($item.file): $($item.reason)"
    }

    $totalHits = 0
    foreach ($entry in $scanMappings) { $totalHits += $entry.totalOccurrences }
    Add-RebindLog $Writer "---"
    Add-RebindLog $Writer "SCAN DONE: $($scanMappings.Count) mapping(s), $($manifest.Count) file(s)"
    Add-RebindLog $Writer "Total hits: $totalHits"
    if ($newGuidPresence.Count -gt 0) { Add-RebindLog $Writer "WARN: $($newGuidPresence.Count) new GUID(s) already present" }
    if ($unreadable.Count -gt 0) { Add-RebindLog $Writer "WARN: $($unreadable.Count) target file(s) or folder(s) could not be inspected; Apply is disabled" }

    return [ordered]@{
        mappings = @($scanMappings)
        newGuidPresence = @($newGuidPresence)
        scannedFiles = @($manifest | ForEach-Object { $_.file })
        targetFileCount = $listing.Files.Count
        matchedFileCount = $manifest.Count
        manifest = @($manifest)
        unreadableFiles = @($unreadable)
    }
}

# ============================================================
# Apply and verification
# ============================================================
function Invoke-RebindVerify {
    # Checks every reviewed file directly, then every target file found by a fresh
    # listing. A file that cannot be read or listed fails verification, and every
    # remaining old-GUID line is reported.
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object[]]$Mappings,
        [AllowEmptyCollection()][object[]]$Manifest = @(),
        [hashtable]$Writer
    )

    $ErrorActionPreference = "Stop"
    Add-RebindLog $Writer "=== VERIFY ==="
    $remaining = [ordered]@{}
    $newCounts = [ordered]@{}
    foreach ($m in $Mappings) { $remaining[$m.OldGuid] = New-Object System.Collections.ArrayList; $newCounts[$m.NewGuid] = 0 }
    $problems = New-Object System.Collections.ArrayList
    $checked = @{}
    $reviewedChecked = 0

    $inspect = {
        param([string]$Relative, [string]$FullName)
        $content = Read-RebindTextFile -Path $FullName
        foreach ($m in $Mappings) {
            $old = Find-RebindGuidLines -Text $content.Text -Guid $m.OldGuid
            foreach ($line in $old.Lines) { [void]$remaining[$m.OldGuid].Add([ordered]@{ file = $Relative; line = $line.line; text = $line.text }) }
            $newCounts[$m.NewGuid] += (Find-RebindGuidLines -Text $content.Text -Guid $m.NewGuid).Count
        }
    }

    foreach ($entry in @($Manifest)) {
        $relative = [string]$entry.file
        $checked[$relative.ToLowerInvariant()] = $true
        $full = Join-RebindPath $Root $relative
        if (-not [System.IO.File]::Exists($full)) {
            [void]$problems.Add([ordered]@{ file = $relative; reason = "Reviewed file is missing at verification" })
            continue
        }
        try {
            & $inspect $relative $full
            $reviewedChecked++
        } catch {
            [void]$problems.Add([ordered]@{ file = $relative; reason = "Reviewed file could not be read at verification: " + (Get-RebindSafeText $_.Exception.Message 200) })
        }
    }

    $listing = Get-RebindTargetFiles -Root $Root
    foreach ($listError in $listing.Errors) {
        [void]$problems.Add([ordered]@{ file = $listError.file; reason = $listError.reason })
    }
    $otherFiles = 0
    foreach ($file in $listing.Files) {
        if ($checked.ContainsKey($file.RelativePath.ToLowerInvariant())) { continue }
        $otherFiles++
        try {
            & $inspect $file.RelativePath $file.FullName
        } catch {
            [void]$problems.Add([ordered]@{ file = $file.RelativePath; reason = "Could not be read at verification: " + (Get-RebindSafeText $_.Exception.Message 200) })
        }
    }

    $remainingCount = 0
    $oldGuidsRemaining = [ordered]@{}
    foreach ($m in $Mappings) {
        $lines = $remaining[$m.OldGuid]
        if ($lines.Count -gt 0) {
            $remainingCount += $lines.Count
            $oldGuidsRemaining[$m.OldGuid] = @($lines)
            Add-RebindLog $Writer "FAIL: $($m.Type) $($m.OldGuid.Substring(0, 8))... still present on $($lines.Count) line(s):"
            foreach ($line in $lines) { Add-RebindLog $Writer "  $($line.file):$($line.line): $($line.text)" }
        } else {
            Add-RebindLog $Writer "OK: $($m.Type) $($m.OldGuid.Substring(0, 8))... removed"
        }
        Add-RebindLog $Writer "  New: $($m.NewGuid.Substring(0, 8))... = $($newCounts[$m.NewGuid])"
    }
    foreach ($problem in $problems) { Add-RebindLog $Writer "FAIL: $($problem.file): $($problem.reason)" }

    $manifestCount = @($Manifest).Count
    $ok = ($manifestCount -gt 0) -and ($reviewedChecked -eq $manifestCount) -and ($remainingCount -eq 0) -and ($problems.Count -eq 0)
    return [ordered]@{
        ok = $ok
        reviewedFiles = $manifestCount
        reviewedFilesChecked = $reviewedChecked
        otherFilesChecked = $otherFiles
        remainingCount = $remainingCount
        oldGuidsRemaining = $oldGuidsRemaining
        newGuidCounts = $newCounts
        problems = @($problems)
    }
}

function Invoke-RebindApply {
    # Rewrites only the files Scan reviewed. All of them are re-checked against their
    # Scan hash before the first write; a mismatch writes nothing. Each file is checked
    # again just before its own write, replaced atomically in its original encoding, and
    # counted only after the write succeeded. The first failed write stops the run.
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object[]]$Mappings,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Manifest,
        [hashtable]$Writer
    )

    $ErrorActionPreference = "Stop"
    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $problems = New-Object System.Collections.ArrayList
    $filesChanged = New-Object System.Collections.ArrayList
    $notWritten = New-Object System.Collections.ArrayList
    $totals = @{}
    foreach ($m in $Mappings) { $totals[$m.OldGuid] = 0 }

    Add-RebindLog $Writer "=== REPLACE ==="
    Add-RebindLog $Writer "Path: $Root"
    Add-RebindLog $Writer "Mappings: $($Mappings.Count)"
    Add-RebindLog $Writer "Reviewed files: $(@($Manifest).Count)"

    foreach ($entry in @($Manifest)) {
        $relative = [string]$entry.file
        $full = Join-RebindPath $Root $relative
        if (-not [System.IO.File]::Exists($full)) {
            [void]$problems.Add([ordered]@{ file = $relative; reason = "Missing since Scan" })
            continue
        }
        try {
            $current = Read-RebindTextFile -Path $full
            if ($current.Hash -ne [string]$entry.hash) {
                [void]$problems.Add([ordered]@{ file = $relative; reason = "Changed since Scan" })
            }
        } catch {
            [void]$problems.Add([ordered]@{ file = $relative; reason = "Unreadable since Scan: " + (Get-RebindSafeText $_.Exception.Message 200) })
        }
    }

    if ($problems.Count -gt 0) {
        foreach ($problem in $problems) { Add-RebindLog $Writer "ERROR: $($problem.file): $($problem.reason)" }
        Add-RebindLog $Writer "Nothing was written: the reviewed files no longer match the Scan."
        foreach ($entry in @($Manifest)) { [void]$notWritten.Add([string]$entry.file) }
    } else {
        $stopped = $false
        foreach ($entry in @($Manifest)) {
            $relative = [string]$entry.file
            if ($stopped) { [void]$notWritten.Add($relative); continue }
            $full = Join-RebindPath $Root $relative
            try {
                $current = Read-RebindTextFile -Path $full
            } catch {
                [void]$problems.Add([ordered]@{ file = $relative; reason = "Unreadable before writing: " + (Get-RebindSafeText $_.Exception.Message 200) })
                [void]$notWritten.Add($relative); $stopped = $true; continue
            }
            if ($current.Hash -ne [string]$entry.hash) {
                [void]$problems.Add([ordered]@{ file = $relative; reason = "Changed since Scan (detected before writing)" })
                [void]$notWritten.Add($relative); $stopped = $true; continue
            }

            $text = $current.Text
            $counts = @{}
            foreach ($m in $Mappings) {
                $pattern = [regex]::Escape($m.OldGuid)
                $count = [regex]::Matches($text, $pattern, $options).Count
                if ($count -gt 0) {
                    $text = [regex]::Replace($text, $pattern, [string]$m.NewGuid, $options)
                    $counts[$m.OldGuid] = $count
                }
            }
            if ($counts.Count -eq 0) {
                [void]$notWritten.Add($relative)
                Add-RebindLog $Writer "  ${relative}: no old GUID found, not rewritten"
                continue
            }

            try {
                Write-RebindFileAtomic -Path $full -Bytes (ConvertTo-RebindEncodedBytes -Text $text -Encoding $current.Encoding)
            } catch {
                [void]$problems.Add([ordered]@{ file = $relative; reason = "Write failed: " + (Get-RebindSafeText $_.Exception.Message 200) })
                [void]$notWritten.Add($relative); $stopped = $true
                Add-RebindLog $Writer "ERROR: ${relative}: write failed; stopping before the remaining files"
                continue
            }
            $fileTotal = 0
            foreach ($key in $counts.Keys) { $totals[$key] += $counts[$key]; $fileTotal += $counts[$key] }
            [void]$filesChanged.Add($relative)
            Add-RebindLog $Writer "  ${relative}: $fileTotal"
        }
    }

    $mappingResults = @()
    $totalReplacements = 0
    foreach ($m in $Mappings) {
        $totalReplacements += $totals[$m.OldGuid]
        $mappingResults += [ordered]@{ type = $m.Type; oldGuid = $m.OldGuid; newGuid = $m.NewGuid; replacements = $totals[$m.OldGuid] }
        Add-RebindLog $Writer "  $($m.Type) $($m.OldGuid.Substring(0, 8))... total: $($totals[$m.OldGuid])"
    }
    Add-RebindLog $Writer "---"
    Add-RebindLog $Writer "Total: $totalReplacements replacement(s) written in $($filesChanged.Count) file(s)"
    if ($notWritten.Count -gt 0) { Add-RebindLog $Writer "Not written: $($notWritten -join ', ')" }

    if ($Writer) { Set-RebindPhase $Writer "verifying" }
    $verification = Invoke-RebindVerify -Root $Root -Mappings $Mappings -Manifest $Manifest -Writer $Writer
    $ok = ($problems.Count -eq 0) -and $verification.ok

    return [ordered]@{
        ok = $ok
        filesChanged = @($filesChanged)
        totalReplacements = $totalReplacements
        mappings = @($mappingResults)
        problems = @($problems)
        notWritten = @($notWritten)
        partial = ($filesChanged.Count -gt 0) -and (-not $ok)
        verification = $verification
    }
}

# ============================================================
# Worker (runs in its own process)
# ============================================================
function Write-RebindErrorLog {
    param([string]$Path, [string]$Text)

    if (-not $Path) { return }
    try {
        $line = (Get-Date).ToString("s") + " " + (Get-RebindSafeText $Text 2000) + [Environment]::NewLine
        [System.IO.File]::AppendAllText($Path, $line, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Invoke-RebindWorker {
    # Returns 0 when the operation finished (passed or failed), 1 on an unexpected
    # error, and 3 when another process holds the lock (nothing was written).
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Scan", "Apply")][string]$Mode,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$PayloadBase64,
        [Parameter(Mandatory = $true)][string]$StatusFile,
        [Parameter(Mandatory = $true)][string]$LockFile,
        [string]$ErrorLogPath = ""
    )

    $ErrorActionPreference = "Stop"
    $kind = $Mode.ToLowerInvariant()
    $lock = Enter-RebindLock -Path $LockFile -OperationId $OperationId -Kind $kind -Attempts 10
    if ($null -eq $lock) {
        Write-RebindErrorLog $ErrorLogPath "Rebind $kind $OperationId not started: another Rebind operation holds the lock"
        return 3
    }

    $state = [ordered]@{
        operationId = $OperationId
        kind = $kind
        ownerPid = $PID
        phase = "starting_$kind"
        running = $true
        error = ""
        logs = New-Object System.Collections.ArrayList
        scanResults = $null
        applyResults = $null
        requestSignature = ""
        reportPath = ""
        scanOperationId = ""
        startedAt = (Get-Date).ToUniversalTime().ToString("o")
    }
    $writer = New-RebindStatusWriter -Path $StatusFile -State $state
    try {
        $payload = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PayloadBase64)) | ConvertFrom-Json
        $mappings = @($payload.Mappings | ForEach-Object { [pscustomobject]@{ Type = [string]$_.Type; OldGuid = [string]$_.OldGuid; NewGuid = [string]$_.NewGuid } })
        $root = [string]$payload.ReportPath
        $state.requestSignature = [string]$payload.RequestSignature
        $state.reportPath = $root

        if ($Mode -eq "Scan") {
            $state.phase = "scanning"
            Save-RebindStatus $writer
            $state.scanResults = Invoke-RebindScan -Root $root -Mappings $mappings -Writer $writer
            Add-RebindLog $writer "=== Review scan results, then click Apply to proceed ==="
            Set-RebindPhase $writer "scan_done"
            return 0
        }

        $state.scanOperationId = [string]$payload.ScanOperationId
        $previous = Read-RebindStatus -Path $StatusFile
        $reviewed = $previous.State
        $reason = ""
        if (-not $previous.Readable) { $reason = "The Scan status could not be read" }
        elseif ($null -eq $reviewed -or $reviewed.phase -ne "scan_done") { $reason = "No reviewed Scan is waiting for Apply" }
        elseif ([string]$reviewed.operationId -ne $state.scanOperationId) { $reason = "The Scan you reviewed is no longer the current one" }
        elseif ([string]$reviewed.requestSignature -ne $state.requestSignature) { $reason = "The path or mappings changed after Scan" }
        elseif ($null -eq $reviewed.scanResults -or @($reviewed.scanResults.manifest).Count -eq 0) { $reason = "The reviewed Scan has no file list" }
        elseif (@($reviewed.scanResults.unreadableFiles | Where-Object { $_ }).Count -gt 0) { $reason = "The reviewed Scan could not inspect every target file" }
        if ($reviewed -and $reviewed.scanResults) { $state.scanResults = $reviewed.scanResults }

        $state.phase = "replacing"
        Save-RebindStatus $writer
        if ($reason) {
            Add-RebindLog $writer "ERROR: $reason. Nothing was written. Run Scan again."
            $state.error = "$reason. Nothing was written. Run Scan again."
            Set-RebindPhase $writer "failed"
            return 0
        }

        $manifest = @($reviewed.scanResults.manifest | Where-Object { $_ })
        $results = Invoke-RebindApply -Root $root -Mappings $mappings -Manifest $manifest -Writer $writer
        $state.applyResults = $results
        if ($results.ok) {
            Add-RebindLog $writer "=== PASS ==="
            Add-RebindLog $writer "All old GUIDs removed from the $($manifest.Count) reviewed file(s); no other target file contains them."
            Add-RebindLog $writer "Files changed: $($results.filesChanged.Count)"
            Add-RebindLog $writer "Total replacements: $($results.totalReplacements)"
            Add-RebindLog $writer "IMPORTANT: Open report in Power BI Desktop to confirm connectivity."
            Set-RebindPhase $writer "done"
        } else {
            Add-RebindLog $writer "=== FAILED ==="
            $parts = @()
            if (@($results.problems).Count -gt 0) { $parts += "$(@($results.problems).Count) file problem(s)" }
            if ($results.verification.remainingCount -gt 0) { $parts += "$($results.verification.remainingCount) old-GUID line(s) remain" }
            if (@($results.verification.problems).Count -gt 0) { $parts += "$(@($results.verification.problems).Count) file(s) could not be verified" }
            if ($results.partial) { $parts += "$($results.filesChanged.Count) file(s) were already changed" }
            if ($parts.Count -eq 0) { $parts += "verification did not pass" }
            $state.error = "Rebind did not complete: " + ($parts -join "; ") + "."
            Add-RebindLog $writer $state.error
            Set-RebindPhase $writer "failed"
        }
        return 0
    } catch {
        $message = Get-RebindSafeText $_.Exception.Message
        Write-RebindErrorLog $ErrorLogPath "Rebind $kind $OperationId failed: $message"
        try {
            Add-RebindLog $writer "ERROR during ${kind}: $message"
            $state.error = $message
            Set-RebindPhase $writer "failed"
        } catch { }
        return 1
    } finally {
        $lock.Dispose()
    }
}

# ============================================================
# Server side
# ============================================================
function ConvertTo-RebindProcessArgument {
    param([string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function New-RebindWorkerStartInfo {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Scan", "Apply")][string]$Mode,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][hashtable]$Payload,
        [Parameter(Mandatory = $true)][hashtable]$Paths
    )

    $json = ConvertTo-Json -InputObject $Payload -Depth 10 -Compress
    $payloadBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
    $arguments = @(
        "-NoProfile"
        "-ExecutionPolicy Bypass"
        "-WindowStyle Hidden"
        "-File $(ConvertTo-RebindProcessArgument $Paths.RunnerPath)"
        "-Mode $Mode"
        "-OperationId $OperationId"
        "-PayloadBase64 $payloadBase64"
        "-StatusFile $(ConvertTo-RebindProcessArgument $Paths.StatusFile)"
        "-LockFile $(ConvertTo-RebindProcessArgument $Paths.LockFile)"
    )
    if ($Paths.ErrorLogPath) { $arguments += "-ErrorLogPath $(ConvertTo-RebindProcessArgument $Paths.ErrorLogPath)" }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = $arguments -join " "
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false
    return $psi
}

function Wait-RebindWorkerOwnership {
    # Owned: the status names this operation. Busy: the worker found the lock held.
    # Exited: it ended without owning anything. Timeout: still silent.
    param(
        [Parameter(Mandatory = $true)][string]$StatusFile,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $status = Read-RebindStatus -Path $StatusFile -Attempts 1
        if ($status.State -and [string]$status.State.operationId -eq $OperationId) { return [pscustomobject]@{ Result = "Owned"; ExitCode = $null } }
        if ($Process.HasExited) {
            $status = Read-RebindStatus -Path $StatusFile
            if ($status.State -and [string]$status.State.operationId -eq $OperationId) { return [pscustomobject]@{ Result = "Owned"; ExitCode = $Process.ExitCode } }
            $result = if ($Process.ExitCode -eq 3) { "Busy" } else { "Exited" }
            return [pscustomobject]@{ Result = $result; ExitCode = $Process.ExitCode }
        }
        if ((Get-Date) -gt $deadline) { return [pscustomobject]@{ Result = "Timeout"; ExitCode = $null } }
        Start-Sleep -Milliseconds 100
    }
}

function Start-RebindOperation {
    # Validates a Scan or Apply request, starts the worker and waits until it owns the
    # status. Returns StatusCode and Body. A refused request changes nothing on disk.
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Scan", "Apply")][string]$Mode,
        [AllowNull()][object]$Body,
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [int]$TimeoutSeconds = 30
    )

    $ErrorActionPreference = "Stop"
    $request = Get-RebindRequest $Body
    if (-not $request.Ok) { return @{ StatusCode = 400; Body = @{ ok = $false; error = $request.Error } } }
    if (Test-RebindLockHeld -Path $Paths.LockFile) {
        return @{ StatusCode = 409; Body = @{ ok = $false; error = "Another rebind operation is already running" } }
    }

    $payload = @{ ReportPath = $request.ReportPath; Mappings = @($request.Mappings); RequestSignature = $request.Signature }
    if ($Mode -eq "Apply") {
        $scanOperationId = [string]$Body.ScanOperationId
        if ([string]::IsNullOrWhiteSpace($scanOperationId)) {
            return @{ StatusCode = 409; Body = @{ ok = $false; error = "Run Scan and review its summary before applying changes" } }
        }
        $status = Read-RebindStatus -Path $Paths.StatusFile
        if (-not $status.Readable) {
            return @{ StatusCode = 503; Body = @{ ok = $false; error = "The Rebind status could not be read, so the reviewed Scan cannot be confirmed. Run Scan again." } }
        }
        $current = $status.State
        if ($null -eq $current -or $current.running -eq $true -or $current.phase -ne "scan_done") {
            return @{ StatusCode = 409; Body = @{ ok = $false; error = "Run Scan and review its summary before applying changes" } }
        }
        if ([string]$current.operationId -ne $scanOperationId) {
            return @{ StatusCode = 409; Body = @{ ok = $false; error = "The Scan you reviewed is no longer the current one. Run Scan again." } }
        }
        if ([string]$current.requestSignature -ne $request.Signature) {
            return @{ StatusCode = 409; Body = @{ ok = $false; error = "The path or mappings changed after Scan. Run Scan again before applying." } }
        }
        $hits = 0
        foreach ($m in @($current.scanResults.mappings)) { if ($m) { $hits += [int]$m.totalOccurrences } }
        if ($hits -le 0) {
            return @{ StatusCode = 409; Body = @{ ok = $false; error = "Scan found no old GUID occurrences, so there is nothing to apply" } }
        }
        $unreadable = @($current.scanResults.unreadableFiles | Where-Object { $_ }).Count
        if ($unreadable -gt 0) {
            return @{ StatusCode = 409; Body = @{ ok = $false; error = "Scan could not inspect $unreadable target file(s) or folder(s), so Apply is disabled. Fix access and run Scan again." } }
        }
        $payload.ScanOperationId = $scanOperationId
    }

    $operationId = [Guid]::NewGuid().ToString("N")
    $psi = New-RebindWorkerStartInfo -Mode $Mode -OperationId $operationId -Payload $payload -Paths $Paths
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return @{ StatusCode = 500; Body = @{ ok = $false; error = "The Rebind worker could not be started: $(Get-RebindSafeText $_.Exception.Message 200)" } }
    }
    $wait = Wait-RebindWorkerOwnership -StatusFile $Paths.StatusFile -OperationId $operationId -Process $process -TimeoutSeconds $TimeoutSeconds
    switch ($wait.Result) {
        "Owned" { return @{ StatusCode = 200; Body = @{ ok = $true; operationId = $operationId } } }
        "Busy" { return @{ StatusCode = 409; Body = @{ ok = $false; error = "Another rebind operation is already running" } } }
        "Exited" { return @{ StatusCode = 500; Body = @{ ok = $false; error = "The Rebind worker stopped before it started (exit code $($wait.ExitCode)). See logs\rebind-worker-errors.log." } } }
        default { return @{ StatusCode = 504; Body = @{ ok = $false; operationId = $operationId; error = "The Rebind worker did not report within $TimeoutSeconds seconds. Check the Rebind status before starting again." } } }
    }
}

function Invoke-RebindCancel {
    # Clears a reviewed Scan decision. invalidated = $true only when no decision for
    # the given operation can be applied any more.
    param([Parameter(Mandatory = $true)][hashtable]$Paths, [string]$OperationId = "")

    $ErrorActionPreference = "Stop"
    $lock = Enter-RebindLock -Path $Paths.LockFile -OperationId "cancel" -Kind "server" -Attempts 3
    if ($null -eq $lock) {
        return @{ StatusCode = 409; Body = @{ ok = $false; invalidated = $false; error = "A rebind operation is still running" } }
    }
    try {
        $status = Read-RebindStatus -Path $Paths.StatusFile
        if (-not $status.Readable) {
            return @{ StatusCode = 503; Body = @{ ok = $false; invalidated = $false; error = "The Rebind status could not be read, so the Scan decision could not be cleared" } }
        }
        $state = $status.State
        if ($null -eq $state -or $state.phase -ne "scan_done") {
            return @{ StatusCode = 200; Body = @{ ok = $true; invalidated = $true } }
        }
        if ($OperationId -and [string]$state.operationId -ne $OperationId) {
            return @{ StatusCode = 200; Body = @{ ok = $true; invalidated = $true; superseded = $true } }
        }
        Set-RebindStateValue $state "phase" "cancelled"
        Set-RebindStateValue $state "running" $false
        Set-RebindStateValue $state "requestSignature" ""
        Set-RebindStateValue $state "cancelledAt" ((Get-Date).ToUniversalTime().ToString("o"))
        try {
            Write-RebindJsonAtomic -Path $Paths.StatusFile -Value $state
        } catch {
            return @{ StatusCode = 500; Body = @{ ok = $false; invalidated = $false; error = "The Scan decision could not be cleared: $(Get-RebindSafeText $_.Exception.Message 200)" } }
        }
        return @{ StatusCode = 200; Body = @{ ok = $true; invalidated = $true } }
    } finally {
        $lock.Dispose()
    }
}

function Set-RebindInterruptedState {
    # Caller holds the lock. Marks a record whose worker is gone as failed, keeping
    # its logs and results so partial Apply changes stay visible.
    param([Parameter(Mandatory = $true)][string]$StatusFile, [Parameter(Mandatory = $true)][object]$State)

    Set-RebindStateValue $State "running" $false
    Set-RebindStateValue $State "phase" "failed"
    Set-RebindStateValue $State "requestSignature" ""
    Set-RebindStateValue $State "error" "The Rebind worker stopped before it finished. If this was Apply, some files may already be changed; run Scan again to see what remains."
    Set-RebindStateValue $State "interrupted" $true
    Write-RebindJsonAtomic -Path $StatusFile -Value $State
}

function Initialize-RebindStatus {
    # Server startup. A live worker keeps its lock and its status untouched. Without
    # one: a record still marked running becomes "interrupted", a reviewed Scan
    # decision is cleared, and a missing or unreadable record becomes idle.
    param([Parameter(Mandatory = $true)][hashtable]$Paths)

    $lock = Enter-RebindLock -Path $Paths.LockFile -OperationId "startup" -Kind "server" -Attempts 3
    if ($null -eq $lock) { return "WorkerActive" }
    try {
        $status = Read-RebindStatus -Path $Paths.StatusFile
        if (-not $status.Exists -or -not $status.Readable) {
            $note = if ($status.Readable) { "" } else { "The previous Rebind status could not be read and was reset." }
            Write-RebindJsonAtomic -Path $Paths.StatusFile -Value ([ordered]@{ operationId = ""; phase = "idle"; running = $false; error = $note; logs = @() })
            return $(if ($status.Readable) { "Idle" } else { "ResetUnreadable" })
        }
        $state = $status.State
        if ($state.running -eq $true) {
            Set-RebindInterruptedState -StatusFile $Paths.StatusFile -State $state
            return "Interrupted"
        }
        if ($state.phase -eq "scan_done") {
            Write-RebindJsonAtomic -Path $Paths.StatusFile -Value ([ordered]@{ operationId = ""; phase = "idle"; running = $false; error = ""; logs = @() })
            return "ScanDecisionCleared"
        }
        return "Kept"
    } finally {
        $lock.Dispose()
    }
}

function Get-RebindStatusResponse {
    # Status for the page. A record marked running whose worker is gone is converted
    # to "interrupted" once, under the lock.
    param([Parameter(Mandatory = $true)][hashtable]$Paths)

    $status = Read-RebindStatus -Path $Paths.StatusFile
    if (-not $status.Exists) { return @{ StatusCode = 200; Body = @{ operationId = ""; phase = "idle"; running = $false; error = ""; logs = @() } } }
    if (-not $status.Readable) {
        return @{ StatusCode = 503; Body = @{ ok = $false; phase = "unknown"; error = "The Rebind status could not be read" } }
    }
    $state = $status.State
    if ($state.running -eq $true) {
        $lock = Enter-RebindLock -Path $Paths.LockFile -OperationId "status" -Kind "server"
        if ($null -ne $lock) {
            try {
                $again = Read-RebindStatus -Path $Paths.StatusFile
                if ($again.Readable -and $again.State -and $again.State.running -eq $true -and [string]$again.State.operationId -eq [string]$state.operationId) {
                    Set-RebindInterruptedState -StatusFile $Paths.StatusFile -State $again.State
                    $state = $again.State
                } elseif ($again.Readable -and $again.State) {
                    $state = $again.State
                }
            } finally {
                $lock.Dispose()
            }
        }
    }
    return @{ StatusCode = 200; Body = $state }
}
