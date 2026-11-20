# Offline regression tests for Rebind: saved profiles, the operation lock and status
# ownership, cancellation, Scan/Apply bound to a reviewed manifest, and verification.
#
# Everything runs against a disposable folder under %TEMP% whose name has spaces and
# square brackets. The only child processes are runtime\Invoke-RebindRun.ps1 (copied
# into that folder) and a fake worker that just holds the lock. Nothing starts
# server.ps1, contacts Power BI, or touches this repository's profiles or status.
#
# Run with Windows PowerShell 5.1:  powershell.exe -NoProfile -File _rebind-tests.ps1
$ErrorActionPreference = "Stop"

$script:passed = 0
$script:failed = @()
function Check {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:passed++ } else { $script:failed += $Message; Write-Host "FAIL: $Message" -ForegroundColor Red }
}

$repoCore = Join-Path $PSScriptRoot "runtime\rebind-core.ps1"
$repoRunner = Join-Path $PSScriptRoot "runtime\Invoke-RebindRun.ps1"
. $repoCore

$OLD_WS = "00000000-0000-0000-0000-0000000000a1"
$OLD_DF = "00000000-0000-0000-0000-0000000000a2"
$NEW_WS = "00000000-0000-0000-0000-0000000000b1"
$NEW_DF = "00000000-0000-0000-0000-0000000000b2"
$mappingBody = @(
    [pscustomobject]@{ Type = "Workspace"; OldGuid = $OLD_WS.ToUpperInvariant(); NewGuid = $NEW_WS },
    [pscustomobject]@{ Type = "Dataflow"; OldGuid = $OLD_DF; NewGuid = $NEW_DF }
)
$mappings = @(
    [pscustomobject]@{ Type = "Workspace"; OldGuid = $OLD_WS; NewGuid = $NEW_WS },
    [pscustomobject]@{ Type = "Dataflow"; OldGuid = $OLD_DF; NewGuid = $NEW_DF }
)

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("rebind tests [" + [Guid]::NewGuid().ToString("N").Substring(0, 8) + "]")
[System.IO.Directory]::CreateDirectory($root) | Out-Null
$fakeWorkers = @()

function Get-FileHashText([string]$Path) { return Get-RebindHash ([System.IO.File]::ReadAllBytes($Path)) }

function Write-Bytes([string]$Path, [byte[]]$Bytes) {
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path)) | Out-Null
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
}

function New-Fixture {
    # A small PBIP-shaped folder. Encodings: UTF-8 without BOM, UTF-8 with BOM,
    # UTF-16 LE with BOM. One file has the workspace GUID on three lines (twice on one).
    param([string]$Name)
    $dir = Join-Path $root $Name
    [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    Write-Bytes (Join-Path $dir "Sample.pbip") ([System.Text.Encoding]::ASCII.GetBytes('{"version":"1.0"}'))
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    $utf16 = New-Object System.Text.UnicodeEncoding($false, $true)
    $model = "table Sales`r`n  source = PowerPlatform.Dataflows([workspaceId=`"$OLD_WS`"])`r`n  // $OLD_WS and $($OLD_WS.ToUpperInvariant())`r`n  dataflowId = `"$OLD_DF`"`r`n  note = `"$OLD_WS`"`r`n"
    Write-Bytes (Join-Path $dir "Sample.SemanticModel\definition\tables\Sales.tmdl") ($utf8.GetBytes($model))
    $report = "{`"datasetReference`":{`"workspace`":`"$OLD_WS`"},`"label`":`"Prodazhi`"}"
    Write-Bytes (Join-Path $dir "Sample.Report\definition.json") ($utf8Bom.GetPreamble() + $utf8Bom.GetBytes($report))
    $pages = "{`"workspace`":`"$OLD_WS`",`"other`":`"$OLD_DF`"}"
    Write-Bytes (Join-Path $dir "Sample.Report\pages [1]\page.json") ($utf16.GetPreamble() + $utf16.GetBytes($pages))
    Write-Bytes (Join-Path $dir "Sample.Report\untouched.json") ($utf8.GetBytes('{"a":1}'))
    Write-Bytes (Join-Path $dir "Sample.SemanticModel\.pbi\cache.json") ($utf8.GetBytes("{`"w`":`"$OLD_WS`"}"))
    return $dir
}

function New-Paths([string]$Name) {
    $dir = Join-Path $root ("state " + $Name)
    [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    return @{
        StatusFile = Join-Path $dir "rebind-status.json"
        LockFile = Join-Path $dir "rebind.lock"
        RunnerPath = $script:runnerCopy
        ErrorLogPath = Join-Path $dir "rebind-worker-errors.log"
    }
}

function Wait-Terminal([hashtable]$Paths, [string]$OperationId, [int]$Seconds = 90) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $s = (Read-RebindStatus -Path $Paths.StatusFile).State
        if ($s -and $s.operationId -eq $OperationId -and $s.phase -in @("scan_done", "done", "failed")) { return $s }
        Start-Sleep -Milliseconds 200
    }
    throw "Operation $OperationId did not finish within $Seconds s"
}

function Start-FakeWorker([hashtable]$Paths, [string]$OperationId) {
    # Holds the lock and writes a running Apply status, like a live worker mid-run.
    $ready = $Paths.LockFile + ".ready"
    $script = Join-Path $root "fake worker.ps1"
    if (-not (Test-Path -LiteralPath $script)) {
        [System.IO.File]::WriteAllText($script, @'
param([string]$Core, [string]$Lock, [string]$Status, [string]$Ready, [string]$OperationId)
$ErrorActionPreference = "Stop"
. $Core
$held = Enter-RebindLock -Path $Lock -OperationId $OperationId -Kind "apply"
Write-RebindJsonAtomic -Path $Status -Value ([ordered]@{ operationId = $OperationId; kind = "apply"; phase = "replacing"; running = $true; error = ""; logs = @(); requestSignature = "sig" })
[System.IO.File]::WriteAllText($Ready, "ready")
Start-Sleep -Seconds 120
'@)
    }
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Core `"$repoCore`" -Lock `"$($Paths.LockFile)`" -Status `"$($Paths.StatusFile)`" -Ready `"$ready`" -OperationId $OperationId"
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Test-Path -LiteralPath $ready)) {
        if ((Get-Date) -gt $deadline -or $process.HasExited) { throw "Fake worker did not start" }
        Start-Sleep -Milliseconds 100
    }
    $script:fakeWorkers += $process
    return $process
}

try {
    # Runner copied into a folder with spaces and brackets, as an installed copy might be.
    $appRuntime = Join-Path $root "app [copy]\runtime"
    [System.IO.Directory]::CreateDirectory($appRuntime) | Out-Null
    Copy-Item -LiteralPath $repoCore -Destination (Join-Path $appRuntime "rebind-core.ps1")
    Copy-Item -LiteralPath $repoRunner -Destination (Join-Path $appRuntime "Invoke-RebindRun.ps1")
    $script:runnerCopy = Join-Path $appRuntime "Invoke-RebindRun.ps1"

    # ============================================================
    # 1. Saved profiles
    # ============================================================
    $profilesFile = Join-Path $root "profiles\rebind-profiles.json"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $profilesFile)) | Out-Null
    $legacy = '[{"name":"Legacy","reportPath":"C:\\PBIP\\Legacy [x]","mappings":[{"id":1730000000000,"type":"Workspace","fromId":"' + $OLD_WS + '","toId":"' + $NEW_WS + '"},{"id":"1);alert(1);//","type":"Dataflow","fromId":"' + $OLD_DF + '","toId":"partial"}]},{"name":"Only one row","reportPath":"","mappings":[{"id":5,"type":"Dataset","fromId":"","toId":""}]}]'
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllBytes($profilesFile, $utf8Bom.GetPreamble() + $utf8Bom.GetBytes($legacy))

    $read = Read-RebindProfileFile -Path $profilesFile
    Check ($read.Ok -and @((ConvertFrom-Json $read.Json)).Count -eq 2) "Legacy profile file with BOM and row IDs loads as a two-item list"

    $saved = Save-RebindProfileFile -Path $profilesFile -Json $legacy
    Check ($saved.StatusCode -eq 200) "Legacy collection (numeric and hostile row IDs, unfinished row) is accepted"
    $stored = [System.IO.File]::ReadAllText($profilesFile)
    Check ($stored -notmatch '"id"' -and $stored -notmatch 'alert') "Row IDs are not stored"
    Check ([System.IO.File]::ReadAllBytes($profilesFile)[0] -ne 0xEF) "Saved profiles have no byte order mark"
    $storedData = ConvertFrom-Json $stored
    Check ($stored.StartsWith("[{") -and $storedData[1].mappings.Count -eq 1 -and $stored -match '"mappings":\[\{') "One-row profile keeps its mappings as a JSON array"
    Check ($storedData[0].mappings[1].toId -eq "partial" -and $storedData[0].reportPath -eq "C:\PBIP\Legacy [x]") "Draft values and bracketed paths are kept"

    $draft = Save-RebindProfileFile -Path $profilesFile -Json '[{"name":"Draft","reportPath":"","mappings":[]}]'
    Check ($draft.StatusCode -eq 200) "A draft with no folder and no mappings can be saved"
    Check ((Save-RebindProfileFile -Path $profilesFile -Json '[]').StatusCode -eq 200) "An empty list can be saved (last profile deleted)"
    [void](Save-RebindProfileFile -Path $profilesFile -Json $legacy)
    $before = Get-FileHashText $profilesFile

    $rejected = @(
        @{ Name = "not JSON"; Json = "[{" },
        @{ Name = "not a list"; Json = '{"name":"x"}' },
        @{ Name = "unknown profile field"; Json = '[{"name":"x","reportPath":"","mappings":[],"onclick":"alert(1)"}]' },
        @{ Name = "unknown row field"; Json = '[{"name":"x","reportPath":"","mappings":[{"type":"Workspace","fromId":"","toId":"","html":"<b>"}]}]' },
        @{ Name = "control character in name"; Json = '[{"name":"x\u0000y","reportPath":"","mappings":[]}]' },
        @{ Name = "duplicate names"; Json = '[{"name":"A","reportPath":"","mappings":[]},{"name":"A","reportPath":"","mappings":[]}]' },
        @{ Name = "unsupported type"; Json = '[{"name":"A","reportPath":"","mappings":[{"type":"Script","fromId":"","toId":""}]}]' },
        @{ Name = "non-text GUID field"; Json = '[{"name":"A","reportPath":"","mappings":[{"type":"Workspace","fromId":{"a":1},"toId":""}]}]' },
        @{ Name = "blank name"; Json = '[{"name":"  ","reportPath":"","mappings":[]}]' },
        @{ Name = "mappings not a list"; Json = '[{"name":"A","reportPath":"","mappings":"x"}]' }
    )
    foreach ($case in $rejected) {
        $result = Save-RebindProfileFile -Path $profilesFile -Json $case.Json
        Check ($result.StatusCode -eq 400 -and -not $result.Body.ok) "Rejected save ($($case.Name)) returns 400"
        Check ((Get-FileHashText $profilesFile) -eq $before) "Rejected save ($($case.Name)) leaves the saved file byte-identical"
    }
    $tooMany = "[" + ((1..201 | ForEach-Object { '{"type":"Workspace","fromId":"","toId":""}' }) -join ",") + "]"
    $result = Save-RebindProfileFile -Path $profilesFile -Json ('[{"name":"Big","reportPath":"","mappings":' + $tooMany + '}]')
    Check ($result.StatusCode -eq 400 -and (Get-FileHashText $profilesFile) -eq $before) "Too many rows are rejected and the file is unchanged"

    (Get-Item -LiteralPath $profilesFile).IsReadOnly = $true
    $result = Save-RebindProfileFile -Path $profilesFile -Json '[{"name":"New","reportPath":"","mappings":[]}]'
    (Get-Item -LiteralPath $profilesFile).IsReadOnly = $false
    Check ($result.StatusCode -eq 500 -and (Get-FileHashText $profilesFile) -eq $before) "A save whose write fails keeps the previous profiles"
    Check (@(Get-ChildItem -LiteralPath (Split-Path -Parent $profilesFile) -Force -Filter "*.rebind-tmp").Count -eq 0) "A failed save leaves no temporary file"

    [System.IO.File]::WriteAllText($profilesFile, '[{"name":"cut off')
    $damaged = Get-FileHashText $profilesFile
    Check (-not (Read-RebindProfileFile -Path $profilesFile).Ok) "A damaged profile file is reported, not read as empty"
    $result = Save-RebindProfileFile -Path $profilesFile -Json '[{"name":"New","reportPath":"","mappings":[]}]'
    Check ($result.StatusCode -eq 409 -and (Get-FileHashText $profilesFile) -eq $damaged) "Saving over a damaged profile file is refused and the file is kept"

    # ============================================================
    # 2. Request bodies
    # ============================================================
    Check (-not (ConvertFrom-RebindRequestJson -Text "{not json").Ok) "Malformed JSON request is refused"
    Check (-not (ConvertFrom-RebindRequestJson -Text "[1,2]").Ok) "A JSON array request is refused"
    Check ((ConvertFrom-RebindRequestJson -Text "" -AllowEmpty).Ok) "Cancel accepts an empty body"
    $big = New-Object System.IO.MemoryStream (,([byte[]](New-Object byte[] 2048)))
    Check ((Read-RebindRequestText -Stream $big -MaxBytes 1024).StatusCode -eq 413) "Oversized body is refused"
    Check ((Read-RebindRequestText -Stream (New-Object System.IO.MemoryStream) -DeclaredLength 5000 -MaxBytes 1024).StatusCode -eq 413) "Oversized declared length is refused unread"

    # ============================================================
    # 3. Scan, then Apply through real worker processes
    # ============================================================
    $fixture = New-Fixture "PBIP Sales [prod copy]"
    $paths = New-Paths "e2e"
    $body = [pscustomobject]@{ ReportPath = $fixture; Mappings = $mappingBody }
    $start = Start-RebindOperation -Mode Scan -Body $body -Paths $paths
    Check ($start.StatusCode -eq 200 -and $start.Body.operationId) "Scan starts in a folder with spaces and brackets (runner also in such a folder)"
    $scan = Wait-Terminal $paths $start.Body.operationId
    Check ($scan.phase -eq "scan_done" -and -not $scan.running) "Scan finishes as scan_done"
    $manifest = @($scan.scanResults.manifest)
    Check ($manifest.Count -eq 3) "Manifest lists the three files with old GUIDs (cache and clean files excluded)"
    $encodings = ($manifest | ForEach-Object { $_.encoding } | Sort-Object) -join ","
    Check ($encodings -eq "utf-16le,utf-8,utf-8-bom") "Manifest records each file's encoding ($encodings)"
    $wsScan = @($scan.scanResults.mappings) | Where-Object { $_.oldGuid -eq $OLD_WS }
    $tmdlOccurrence = @($wsScan.occurrences) | Where-Object { $_.file -like "*Sales.tmdl" }
    Check ($tmdlOccurrence.count -eq 4 -and (@($tmdlOccurrence.lines) -join ",") -eq "2,3,5") "Scan counts every match and lists every line (4 matches on lines 2,3,5)"
    $scanHits = 0; foreach ($m in @($scan.scanResults.mappings)) { $scanHits += [int]$m.totalOccurrences }

    $applyNoId = Start-RebindOperation -Mode Apply -Body $body -Paths $paths
    Check ($applyNoId.StatusCode -eq 409) "Apply without the reviewed Scan ID is refused"
    $applyBody = [pscustomobject]@{ ReportPath = $fixture; Mappings = $mappingBody; ScanOperationId = "someone-else" }
    Check ((Start-RebindOperation -Mode Apply -Body $applyBody -Paths $paths).StatusCode -eq 409) "Apply with another Scan's ID is refused"
    $applyBody.ScanOperationId = $start.Body.operationId
    $apply = Start-RebindOperation -Mode Apply -Body $applyBody -Paths $paths
    Check ($apply.StatusCode -eq 200) "Apply bound to the reviewed Scan starts"
    $done = Wait-Terminal $paths $apply.Body.operationId
    Check ($done.phase -eq "done" -and $done.applyResults.ok -and $done.applyResults.verification.ok) "Apply finishes verified"
    Check ([int]$done.applyResults.totalReplacements -eq $scanHits) "Replacements written equal Scan hits ($scanHits)"
    $tmdlBytes = [System.IO.File]::ReadAllBytes((Join-Path $fixture "Sample.SemanticModel\definition\tables\Sales.tmdl"))
    $tmdlText = [System.Text.Encoding]::UTF8.GetString($tmdlBytes)
    Check ($tmdlBytes[0] -ne 0xEF -and $tmdlText -notmatch $OLD_WS -and $tmdlText -match "`r`n" -and ([regex]::Matches($tmdlText, $NEW_WS)).Count -eq 4) "UTF-8 file stays without BOM, keeps CRLF, all matches replaced"
    $reportBytes = [System.IO.File]::ReadAllBytes((Join-Path $fixture "Sample.Report\definition.json"))
    Check ($reportBytes[0] -eq 0xEF -and $reportBytes[1] -eq 0xBB -and $reportBytes[2] -eq 0xBF) "UTF-8 BOM is preserved"
    $pageBytes = [System.IO.File]::ReadAllBytes((Join-Path $fixture "Sample.Report\pages [1]\page.json"))
    $pageText = (New-Object System.Text.UnicodeEncoding($false, $true)).GetString($pageBytes, 2, $pageBytes.Length - 2)
    Check ($pageBytes[0] -eq 0xFF -and $pageBytes[1] -eq 0xFE -and $pageText -match $NEW_WS -and $pageText -match $NEW_DF) "UTF-16 file in a bracketed folder is rewritten as UTF-16 with BOM"
    Check (([System.IO.File]::ReadAllText((Join-Path $fixture "Sample.SemanticModel\.pbi\cache.json"))) -match $OLD_WS) "Files under .pbi are not touched"
    Check ((Start-RebindOperation -Mode Apply -Body $applyBody -Paths $paths).StatusCode -eq 409) "A consumed Scan cannot be applied twice"

    # ============================================================
    # 4. Changes between Scan and Apply (extracted logic, disposable files)
    # ============================================================
    $fixture = New-Fixture "changed after scan"
    $scanResult = Invoke-RebindScan -Root $fixture -Mappings $mappings
    $tmdl = Join-Path $fixture "Sample.SemanticModel\definition\tables\Sales.tmdl"
    [System.IO.File]::AppendAllText($tmdl, "// edited after Scan`r`n")
    $hashesBefore = @{}; foreach ($e in $scanResult.manifest) { $hashesBefore[$e.file] = Get-FileHashText (Join-RebindPath $fixture $e.file) }
    $result = Invoke-RebindApply -Root $fixture -Mappings $mappings -Manifest $scanResult.manifest
    Check (-not $result.ok -and @($result.filesChanged).Count -eq 0 -and -not $result.partial) "A reviewed file changed after Scan: nothing is written"
    Check (@($result.problems | Where-Object { $_.file -like "*Sales.tmdl" -and $_.reason -like "Changed since Scan*" }).Count -eq 1) "The changed file is named"
    $unchanged = $true; foreach ($e in $scanResult.manifest) { if ((Get-FileHashText (Join-RebindPath $fixture $e.file)) -ne $hashesBefore[$e.file]) { $unchanged = $false } }
    Check $unchanged "No reviewed file was rewritten"
    Check ($result.totalReplacements -eq 0 -and $result.verification.remainingCount -gt 0) "No replacements are counted and the remaining old GUIDs are reported"

    $fixture = New-Fixture "missing after scan"
    $scanResult = Invoke-RebindScan -Root $fixture -Mappings $mappings
    Remove-Item -LiteralPath (Join-Path $fixture "Sample.Report\definition.json")
    $result = Invoke-RebindApply -Root $fixture -Mappings $mappings -Manifest $scanResult.manifest
    Check (-not $result.ok -and @($result.problems | Where-Object { $_.reason -eq "Missing since Scan" }).Count -eq 1 -and @($result.filesChanged).Count -eq 0) "A reviewed file that disappeared is named and nothing is written"
    Check (-not $result.verification.ok -and @($result.verification.problems | Where-Object { $_.reason -like "Reviewed file is missing*" }).Count -eq 1) "Verification fails on the missing reviewed file"

    $fixture = New-Fixture "added after scan"
    $scanResult = Invoke-RebindScan -Root $fixture -Mappings $mappings
    Write-Bytes (Join-Path $fixture "Sample.Report\late [new].json") ([System.Text.Encoding]::UTF8.GetBytes("{`"w`":`"$OLD_WS`"}"))
    $result = Invoke-RebindApply -Root $fixture -Mappings $mappings -Manifest $scanResult.manifest
    Check (@($result.filesChanged).Count -eq 3 -and -not $result.ok) "A file added after Scan is not rewritten, and Apply does not report success"
    Check (@($result.verification.oldGuidsRemaining[$OLD_WS] | Where-Object { $_.file -eq "Sample.Report\late [new].json" }).Count -eq 1) "The added file's old-GUID line is reported"

    $fixture = New-Fixture "unreadable at scan"
    Write-Bytes (Join-Path $fixture "Sample.Report\latin1.json") ([byte[]](0x7B, 0x22, 0xE9, 0x22, 0x7D))
    $scanResult = Invoke-RebindScan -Root $fixture -Mappings $mappings
    Check (@($scanResult.unreadableFiles | Where-Object { $_.file -like "*latin1.json" }).Count -eq 1) "A file in an unsupported encoding is listed as not inspected"
    $paths = New-Paths "unreadable"
    $start = Start-RebindOperation -Mode Scan -Body ([pscustomobject]@{ ReportPath = $fixture; Mappings = $mappingBody }) -Paths $paths
    $scan = Wait-Terminal $paths $start.Body.operationId
    $result = Start-RebindOperation -Mode Apply -Body ([pscustomobject]@{ ReportPath = $fixture; Mappings = $mappingBody; ScanOperationId = $start.Body.operationId }) -Paths $paths
    Check ($result.StatusCode -eq 409 -and $result.Body.error -like "*could not inspect*") "Apply is refused when Scan could not inspect every target file"

    # ============================================================
    # 5. Failed write and multiple remaining matches in one file
    # ============================================================
    $fixture = New-Fixture "failed write"
    $scanResult = Invoke-RebindScan -Root $fixture -Mappings $mappings
    $order = @($scanResult.manifest | ForEach-Object { $_.file })
    $blocked = Join-RebindPath $fixture $order[1]
    (Get-Item -LiteralPath $blocked).IsReadOnly = $true
    $result = Invoke-RebindApply -Root $fixture -Mappings $mappings -Manifest $scanResult.manifest
    (Get-Item -LiteralPath $blocked).IsReadOnly = $false
    Check (-not $result.ok -and $result.partial) "A failed write makes the result failed and partial"
    Check ((@($result.filesChanged) -join "|") -eq $order[0]) "Only the file written before the failure is reported as changed"
    Check (@($result.problems | Where-Object { $_.file -eq $order[1] -and $_.reason -like "Write failed*" }).Count -eq 1) "The file whose write failed is named"
    Check ((@($result.notWritten) -join "|") -eq ($order[1] + "|" + $order[2])) "Files after the failure are listed as not written"
    $firstRead = Read-RebindTextFile -Path (Join-RebindPath $fixture $order[0])
    $firstCount = ([regex]::Matches($firstRead.Text, $NEW_WS)).Count + ([regex]::Matches($firstRead.Text, $NEW_DF)).Count
    Check ($result.totalReplacements -eq $firstCount -and $firstCount -gt 0) "Replacements count only the successful write ($firstCount)"
    Check ($result.verification.remainingCount -eq (@($result.verification.oldGuidsRemaining[$OLD_WS]).Count + @($result.verification.oldGuidsRemaining[$OLD_DF]).Count)) "Remaining count equals the listed lines"

    $fixture = New-Fixture "remaining lines"
    $verify = Invoke-RebindVerify -Root $fixture -Mappings $mappings -Manifest @((Invoke-RebindScan -Root $fixture -Mappings $mappings).manifest)
    $tmdlLines = @($verify.oldGuidsRemaining[$OLD_WS] | Where-Object { $_.file -like "*Sales.tmdl" } | ForEach-Object { $_.line })
    Check (($tmdlLines -join ",") -eq "2,3,5") "Verification reports every remaining old-GUID line in one file (2,3,5), not just the first"
    Check (-not $verify.ok) "Verification fails while old GUIDs remain"

    $empty = Invoke-RebindVerify -Root (Join-Path $root "no such folder") -Mappings $mappings -Manifest @([ordered]@{ file = "gone.json"; hash = "x" })
    Check (-not $empty.ok) "Verification does not pass when the folder and its files are gone"
    $emptyDir = Join-Path $root "empty project"; [System.IO.Directory]::CreateDirectory($emptyDir) | Out-Null
    Check (-not (Invoke-RebindVerify -Root $emptyDir -Mappings $mappings -Manifest @()).ok) "Verification does not pass with an empty manifest and no files"

    # ============================================================
    # 6. Ownership: restart, overlap and malformed requests with a live fake worker
    # ============================================================
    $fixture = New-Fixture "ownership"
    $paths = New-Paths "ownership"
    $fake = Start-FakeWorker $paths "fake-live"
    $statusBefore = Get-FileHashText $paths.StatusFile
    Check ((Initialize-RebindStatus -Paths $paths) -eq "WorkerActive") "Server restart sees the live worker"
    Check ((Get-FileHashText $paths.StatusFile) -eq $statusBefore) "Server restart leaves the live worker's status untouched"
    $overlap = Start-RebindOperation -Mode Scan -Body ([pscustomobject]@{ ReportPath = $fixture; Mappings = $mappingBody }) -Paths $paths
    Check ($overlap.StatusCode -eq 409) "A second Scan while a worker runs is refused"
    $bad = Start-RebindOperation -Mode Scan -Body ([pscustomobject]@{ ReportPath = ""; Mappings = @() }) -Paths $paths
    Check ($bad.StatusCode -eq 400) "An invalid second request is refused"
    Check (-not (ConvertFrom-RebindRequestJson -Text '{"ReportPath":').Ok) "A malformed second request is refused before any Rebind call"
    $cancel = Invoke-RebindCancel -Paths $paths -OperationId "fake-live"
    Check ($cancel.StatusCode -eq 409 -and -not $cancel.Body.invalidated) "Cancel while the worker runs is refused and not reported as invalidated"
    $statusNow = Get-RebindStatusResponse -Paths $paths
    Check ($statusNow.Body.running -eq $true -and $statusNow.Body.phase -eq "replacing") "Status still shows the live worker as running"
    Check ((Get-FileHashText $paths.StatusFile) -eq $statusBefore) "No refused request changed the live worker's status"

    $raceStatus = Get-FileHashText $paths.StatusFile
    $workerArgs = @{ Mode = "Scan"; Payload = @{ ReportPath = $fixture; Mappings = $mappings; RequestSignature = "x" }; Paths = $paths }
    $p1 = [System.Diagnostics.Process]::Start((New-RebindWorkerStartInfo -OperationId "race-1" @workerArgs))
    $p2 = [System.Diagnostics.Process]::Start((New-RebindWorkerStartInfo -OperationId "race-2" @workerArgs))
    $p1.WaitForExit(60000) | Out-Null; $p2.WaitForExit(60000) | Out-Null
    Check ($p1.ExitCode -eq 3 -and $p2.ExitCode -eq 3) "Two overlapping workers both stop while the lock is held (exit 3)"
    Check ((Get-FileHashText $paths.StatusFile) -eq $raceStatus) "Overlapping workers wrote nothing"

    [System.IO.File]::WriteAllText($paths.StatusFile, "{ half written")
    Check ((Initialize-RebindStatus -Paths $paths) -eq "WorkerActive") "An unreadable status with a live worker is not reset"
    Check ((Start-RebindOperation -Mode Scan -Body ([pscustomobject]@{ ReportPath = $fixture; Mappings = $mappingBody }) -Paths $paths).StatusCode -eq 409) "An unreadable status does not let another worker start"
    Check ([System.IO.File]::ReadAllText($paths.StatusFile) -eq "{ half written") "The unreadable status was left as found while the worker lives"
    Write-RebindJsonAtomic -Path $paths.StatusFile -Value ([ordered]@{ operationId = "fake-live"; kind = "apply"; phase = "replacing"; running = $true; error = ""; logs = @() })

    $fake.Kill(); $fake.WaitForExit()
    $after = Get-RebindStatusResponse -Paths $paths
    Check ($after.Body.phase -eq "failed" -and $after.Body.interrupted -eq $true -and $after.Body.running -eq $false) "After the worker dies, its record is marked interrupted"
    Check ((Initialize-RebindStatus -Paths $paths) -eq "Kept") "A later restart keeps the interrupted record"
    $fresh = Start-RebindOperation -Mode Scan -Body ([pscustomobject]@{ ReportPath = $fixture; Mappings = $mappingBody }) -Paths $paths
    Check ($fresh.StatusCode -eq 200) "A new Scan can start once the worker is gone"
    [void](Wait-Terminal $paths $fresh.Body.operationId)

    # ============================================================
    # 7. Cancellation
    # ============================================================
    $paths = New-Paths "cancel"
    $fixture = New-Fixture "cancel"
    $scanStart = Start-RebindOperation -Mode Scan -Body ([pscustomobject]@{ ReportPath = $fixture; Mappings = $mappingBody }) -Paths $paths
    [void](Wait-Terminal $paths $scanStart.Body.operationId)
    $other = Invoke-RebindCancel -Paths $paths -OperationId "older-scan"
    Check ($other.Body.ok -and $other.Body.superseded -and (Read-RebindStatus $paths.StatusFile).State.phase -eq "scan_done") "Cancelling a superseded Scan leaves the current decision for its own window"
    $cancel = Invoke-RebindCancel -Paths $paths -OperationId $scanStart.Body.operationId
    $state = (Read-RebindStatus $paths.StatusFile).State
    Check ($cancel.Body.ok -and $cancel.Body.invalidated -and $state.phase -eq "cancelled" -and -not $state.requestSignature) "Cancel clears the reviewed Scan on the server"
    $applyAfter = Start-RebindOperation -Mode Apply -Body ([pscustomobject]@{ ReportPath = $fixture; Mappings = $mappingBody; ScanOperationId = $scanStart.Body.operationId }) -Paths $paths
    Check ($applyAfter.StatusCode -eq 409) "Apply after a confirmed cancel is refused, even with identical parameters"

    [System.IO.File]::WriteAllText($paths.StatusFile, "not json")
    $failedCancel = Invoke-RebindCancel -Paths $paths -OperationId $scanStart.Body.operationId
    Check ($failedCancel.StatusCode -eq 503 -and -not $failedCancel.Body.ok -and -not $failedCancel.Body.invalidated) "Cancel with an unreadable status reports failure, not success"
    Check ([System.IO.File]::ReadAllText($paths.StatusFile) -eq "not json") "A failed cancel does not rewrite the status"

    Write-RebindJsonAtomic -Path $paths.StatusFile -Value ([ordered]@{ operationId = "s1"; phase = "scan_done"; running = $false; requestSignature = "sig"; logs = @() })
    Check ((Initialize-RebindStatus -Paths $paths) -eq "ScanDecisionCleared" -and (Read-RebindStatus $paths.StatusFile).State.phase -eq "idle") "A restart without a worker clears a reviewed Scan decision"

    # ============================================================
    # 8. Server wiring (source checks; server.ps1 is parsed, never started)
    # ============================================================
    $serverSource = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "server.ps1"))
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($serverSource, [ref]$tokens, [ref]$errors)
    Check ($errors.Count -eq 0) "server.ps1 parses"
    Check ($serverSource -notmatch 'Set-RebindFailure|Get-RebindState|_rebind-worker\.ps1') "server.ps1 no longer generates a shared worker script or marks shared state from the error handler"
    $outerTry = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text -match 'Cross-origin requests' }, $true)
    $catchCode = if ($outerTry) { ($outerTry.CatchClauses[0].Body.Extent.Text -split "`n" | Where-Object { $_.Trim() -notlike "#*" }) -join "`n" } else { "" }
    Check ($null -ne $outerTry -and $catchCode -notmatch 'rebindStatusFile|rebindPaths|Set-Rebind|Write-Rebind|Initialize-Rebind') "The general request error handler does not touch Rebind state"
    Check ($serverSource -match 'Initialize-RebindStatus -Paths \$rebindPaths' -and $serverSource -notmatch 'phase = "idle"; running = \$false; error = ""; logs = @\(\) \} \| ConvertTo-Json') "Startup reconciles Rebind status instead of resetting it"
    Check ($serverSource -match 'ConvertFrom-RebindRequestJson -Text \$bodyText\.Text\s+if \(-not \$parsed\.Ok\)') "Scan/Apply parse the body before starting an operation"
    Check ($serverSource -match 'Save-RebindProfileFile -Path \$rebindProfilesFile') "Profile POST goes through validation"
} finally {
    foreach ($process in $fakeWorkers) { try { if (-not $process.HasExited) { $process.Kill() } } catch { } }
    Start-Sleep -Milliseconds 300
    Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer -and $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:failed.Count -gt 0) {
    Write-Host "Rebind tests: $($script:passed) passed, $($script:failed.Count) failed" -ForegroundColor Red
    exit 1
}
Write-Host "Rebind tests OK ($($script:passed) checks)" -ForegroundColor Green
