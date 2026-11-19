# Offline tests for the validation library: parsing, comparison rules, baseline
# selection, run lock, chained-run lookup and email content. No network, sends
# nothing; temporary folders are removed afterwards.
# ASCII only so Windows PowerShell 5.1 reads it correctly.

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot "validation.ps1")
$config = Read-ValidationConfig -Path (Join-Path $projectRoot "reports\example.config.json")
$config | Add-Member -NotePropertyName evaluationDate -NotePropertyValue "2026-11-18" -Force

$script:results = @()
function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = "")
    $script:results += [pscustomobject]@{ Ok = $Condition; Test = $Name; Detail = $Detail }
}

function New-Snapshot {
    # Months yyyy-MM from $FirstMonth for $Count months; values grow slowly.
    param([string]$FirstMonth = "2025-09", [int]$Count = 14, [string]$LatestDate = "2026-10-01T00:00:00", [string]$LoadTime = "2026-11-16T11:12:12")
    $start = [datetime]::ParseExact($FirstMonth + "-01", "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
    $sales = @(); $rows = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $key = $start.AddMonths($i).ToString("yyyy-MM")
        $sales += [pscustomobject]@{ key = $key; value = 300000 + 1000 * $i }
        $rows += [pscustomobject]@{ key = $key; value = 250000 + 500 * $i }
    }
    return [pscustomobject]@{
        capturedAt = "2026-11-18T12:00:00"
        workspaceName = "WS"; reportName = "R"
        checks = @(
            [pscustomobject]@{ id = "sales_by_month"; label = "Sales"; kind = "table"; status = "Ok"; error = ""; value = $null; values = $sales; rowCount = $Count },
            [pscustomobject]@{ id = "rows_total"; label = "Rows"; kind = "scalar"; status = "Ok"; error = ""; value = 29907167; values = @(); rowCount = 1 },
            [pscustomobject]@{ id = "rows_by_month"; label = "Rows per month"; kind = "table"; status = "Ok"; error = ""; value = $null; values = $rows; rowCount = $Count },
            [pscustomobject]@{ id = "fact_max_date"; label = "Latest"; kind = "scalar_date"; status = "Ok"; error = ""; value = $LatestDate; values = @(); rowCount = 1 },
            [pscustomobject]@{ id = "dwh_load_time"; label = "DWH"; kind = "scalar_date"; status = "Ok"; error = ""; value = $LoadTime; values = @(); rowCount = 1 }
        )
    }
}
function Get-Check { param($Compare, [string]$Id) @($Compare.checks | Where-Object { $_.id -eq $Id })[0] }
function Copy-Object { param($Value) $Value | ConvertTo-Json -Depth 12 | ConvertFrom-Json }

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("validation-logic-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)

try {
    # --- Number parsing
    $cases = @(
        @("523344.82", 523344.82), @("523344,82", 523344.82), @("1,5", 1.5), @("1 234,56", 1234.56),
        @("1,234.56", 1234.56), @("1.234,56", 1234.56), @("1,234,567", 1234567), @("30003357", 30003357), @("-0,5", -0.5)
    )
    foreach ($case in $cases) {
        $got = ConvertTo-ValidationNumber $case[0]
        Assert-That "parse '$($case[0])'" ($null -ne $got -and [math]::Abs($got - $case[1]) -lt 1e-9) "got $got"
    }
    Assert-That "parse non-number" ($null -eq (ConvertTo-ValidationNumber "abc"))
    Assert-That "parse JSON number" ((ConvertTo-ValidationNumber 30003357) -eq 30003357)

    # The example config has no informational checks. This fixture adds two
    # back, so the INFO feature (still available to other reports) stays tested.
    $infoConfig = Copy-Object $config
    $infoConfig.checks = @($infoConfig.checks) + @([pscustomobject]@{ id = "dwh_load_time"; label = "DWH"; kind = "scalar_date"; severity = "info" })
    $infoConfig | Add-Member -NotePropertyName derivedChecks -Force -NotePropertyValue @([pscustomobject]@{
        id = "sales_latest_vs_last_year"; label = "Sales vs last year"; kind = "latest_vs_average"; comparison = "lastYear"; severity = "info"
        sourceCheckId = "sales_by_month"; rowCountCheckId = "rows_by_month"; minRowRatio = 0.5; warnDeviationPercent = 40; failDeviationPercent = 70
    })

    # --- Identical snapshots: PASS, informational checks excluded from counts
    $base = New-Snapshot
    $plain = Compare-ValidationSnapshots -Before $base -After (Copy-Object $base) -Config $config
    Assert-That "check removed from the config is skipped" ((@($plain.checks).Count -eq 4) -and $null -eq (Get-Check $plain "dwh_load_time") -and $plain.overall -eq "PASS") "checks=$(@($plain.checks).Count) overall=$($plain.overall)"
    $same = Compare-ValidationSnapshots -Before $base -After (Copy-Object $base) -Config $infoConfig
    Assert-That "identical -> PASS" ($same.overall -eq "PASS") $same.overall
    Assert-That "info checks counted apart" ($same.counts.info -eq 2 -and $same.counts.total -eq 4) "total=$($same.counts.total) info=$($same.counts.info)"
    Assert-That "unchanged freshness within lag -> PASS" ((Get-Check $same "fact_max_date").verdict -eq "PASS")
    $yoy = Get-Check $same "sales_latest_vs_last_year"
    Assert-That "derived is INFO" ($yoy.verdict -eq "INFO") $yoy.verdict
    Assert-That "derived compares 2026-10 with 2025-10" ($yoy.message -like "2026-10 compared with 2025-10*") $yoy.message

    # --- Window moves forward one month: the dropped first month is not a failure
    $shifted = New-Snapshot -FirstMonth "2025-10" -LatestDate "2026-11-01T00:00:00"
    $shift = Compare-ValidationSnapshots -Before $base -After $shifted -Config $config
    Assert-That "window shift -> no FAIL" ($shift.counts.fail -eq 0) "overall=$($shift.overall) fail=$($shift.counts.fail)"
    Assert-That "dropped month not listed" (@((Get-Check $shift "rows_by_month").months | Where-Object { $_.key -eq "2025-09" }).Count -eq 0)

    # --- A month missing inside the window is still a failure
    $gap = Copy-Object $base
    $rowsCheck = @($gap.checks | Where-Object { $_.id -eq "rows_by_month" })[0]
    $rowsCheck.values = @($rowsCheck.values | Where-Object { $_.key -ne "2026-03" })
    $gapCompare = Compare-ValidationSnapshots -Before $base -After $gap -Config $config
    $gapMonth = @((Get-Check $gapCompare "rows_by_month").months | Where-Object { $_.key -eq "2026-03" })[0]
    Assert-That "missing middle month -> FAIL" ($null -ne $gapMonth -and $gapMonth.verdict -eq "FAIL")

    # --- Freshness rules
    $old = New-Snapshot -LatestDate "2026-08-01T00:00:00"
    Assert-That "period older than 2 months -> WARN" ((Get-Check (Compare-ValidationSnapshots -Before $old -After (Copy-Object $old) -Config $config) "fact_max_date").verdict -eq "WARN")
    $back = New-Snapshot -LatestDate "2026-09-01T00:00:00"
    Assert-That "period moving backwards -> FAIL" ((Get-Check (Compare-ValidationSnapshots -Before $base -After $back -Config $config) "fact_max_date").verdict -eq "FAIL")

    # --- Informational check never changes the overall verdict
    $loadBack = New-Snapshot -LoadTime "2026-11-01T00:00:00"
    $loadCompare = Compare-ValidationSnapshots -Before $base -After $loadBack -Config $infoConfig
    $load = Get-Check $loadCompare "dwh_load_time"
    Assert-That "info check keeps its rule verdict" ($load.verdict -eq "INFO" -and $load.ruleVerdict -eq "FAIL") "$($load.verdict)/$($load.ruleVerdict)"
    Assert-That "info FAIL does not fail overall" ($loadCompare.overall -eq "PASS") $loadCompare.overall

    # --- Post-check where every query failed: FAIL, and never a baseline
    $broken = Copy-Object $base
    foreach ($check in $broken.checks) { $check.status = "Error"; $check.error = "(401) Unauthorized"; $check.values = @(); $check.value = $null }
    Assert-That "query errors -> FAIL" ((Compare-ValidationSnapshots -Before $base -After $broken -Config $config).overall -eq "FAIL")

    $runs = Join-Path $temp "runs"
    function New-Run {
        param([string]$Name, [string]$Refresh = "Succeeded", [string]$Verdict = "PASS", [object]$After, [switch]$Accepted, [string]$Fatal = "")
        $folder = Join-Path $runs $Name
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $summary = [pscustomobject]@{ workspaceName = "WS"; reportName = "R"; refreshResult = $Refresh; validationResult = $Verdict; fatalError = $Fatal } | ConvertTo-Json
        [System.IO.File]::WriteAllText((Join-Path $folder "validation-summary.json"), $summary, $utf8)
        [System.IO.File]::WriteAllText((Join-Path $folder "after.json"), ($After | ConvertTo-Json -Depth 12), $utf8)
        if ($Accepted) { [System.IO.File]::WriteAllText((Join-Path $folder "accepted.json"), "{}", $utf8) }
    }
    New-Run -Name "20261101-000000-a" -After $base
    New-Run -Name "20261102-000000-b" -After $base -Verdict "FAIL" -Accepted
    New-Run -Name "20261103-000000-c" -After $base -Verdict "FAIL"
    New-Run -Name "20261104-000000-d" -After $broken
    New-Run -Name "20261105-000000-e" -After $base -Fatal "stopped"
    $one = Resolve-ValidationBaseline -RunsRoot $runs -RunsBack 1 -WorkspaceName "WS" -ReportName "R"
    $two = Resolve-ValidationBaseline -RunsRoot $runs -RunsBack 2 -WorkspaceName "WS" -ReportName "R"
    Assert-That "baseline skips errors, fatal and unaccepted FAIL" ($one.Folder.Name -eq "20261102-000000-b") $one.Folder.Name
    Assert-That "baseline two back" ($two.Folder.Name -eq "20261101-000000-a") $two.Folder.Name

    # --- Run lock
    $lock = Join-Path $temp "report\run.lock"
    Enter-ValidationLock -Path $lock -RunFolder "run-1"
    $refused = ""
    try { Enter-ValidationLock -Path $lock -RunFolder "run-2" } catch { $refused = $_.Exception.Message }
    Assert-That "second lock refused while owner is alive" ($refused -like "Another validation run is already active*") $refused
    Exit-ValidationLock -Path $lock
    Assert-That "lock released" (-not (Test-Path -LiteralPath $lock))
    $stale = [ordered]@{ pid = 999999; processStart = "2000-01-01T00:00:00"; computer = $env:COMPUTERNAME; runFolder = "dead" } | ConvertTo-Json
    [System.IO.File]::WriteAllText($lock, $stale, $utf8)
    Enter-ValidationLock -Path $lock -RunFolder "run-3"
    Assert-That "stale lock replaced" ((Get-Content -LiteralPath $lock -Raw | ConvertFrom-Json).runFolder -eq "run-3")
    Exit-ValidationLock -Path $lock

    # --- Chained run lookup ignores other reports and finds ours
    $chain = Join-Path $temp "chain"
    New-Item -ItemType Directory -Path (Join-Path $chain "20261118-010000-old") -Force | Out-Null
    $existing = @("20261118-010000-old")
    foreach ($spec in @(@("20261118-020000-ours", "WS", "R"), @("20261118-030000-other", "WS", "Other report"))) {
        $folder = Join-Path $chain $spec[0]
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $folder "summary.json"), ([pscustomobject]@{ Workspace = $spec[1]; Report = $spec[2]; Result = "Succeeded" } | ConvertTo-Json), $utf8)
    }
    $found = Find-ValidationChainRun -RunsRoot $chain -ExistingNames $existing -WorkspaceName "WS" -ReportName "R"
    Assert-That "chained run matched by report" ($null -ne $found -and (Split-Path -Leaf $found.Folder) -eq "20261118-020000-ours")

    # --- Artifacts root
    $expanded = Resolve-ValidationArtifactsRoot -ConfigRoot "C:\tool" -Setting "%LOCALAPPDATA%\PowerBIValidation\reports"
    Assert-That "artifacts root expands variables" ($expanded -eq (Join-Path $env:LOCALAPPDATA "PowerBIValidation\reports")) $expanded
    Assert-That "artifacts override wins" ((Resolve-ValidationArtifactsRoot -ConfigRoot "C:\tool" -Setting "x" -Override "D:\data") -eq "D:\data")
    Assert-That "relative artifacts root" ((Resolve-ValidationArtifactsRoot -ConfigRoot "C:\tool" -Setting "artifacts") -eq "C:\tool\artifacts")

    # --- Config selection
    $tool = Join-Path $temp "tool"
    New-Item -ItemType Directory -Path (Join-Path $tool "reports") -Force | Out-Null
    $noneError = ""
    try { Resolve-ValidationConfigPath -ToolRoot $tool | Out-Null } catch { $noneError = $_.Exception.Message }
    Assert-That "no configs -> clear error" ($noneError -like "No report configs*") $noneError
    [System.IO.File]::WriteAllText((Join-Path $tool "reports\alpha.config.json"), "{}", $utf8)
    Assert-That "single config used by default" ((Resolve-ValidationConfigPath -ToolRoot $tool) -like "*\alpha.config.json")
    [System.IO.File]::WriteAllText((Join-Path $tool "reports\beta.config.json"), "{}", $utf8)
    $severalError = ""
    try { Resolve-ValidationConfigPath -ToolRoot $tool | Out-Null } catch { $severalError = $_.Exception.Message }
    Assert-That "several configs -> must choose" ($severalError -like "Several report configs*alpha, beta*") $severalError
    Assert-That "-Report picks by name, any case" ((Resolve-ValidationConfigPath -ToolRoot $tool -Report "BETA") -like "*\beta.config.json")
    $unknownError = ""
    try { Resolve-ValidationConfigPath -ToolRoot $tool -Report "gamma" | Out-Null } catch { $unknownError = $_.Exception.Message }
    Assert-That "unknown report lists the available ones" ($unknownError -like "*Available: alpha, beta") $unknownError
    $explicit = Join-Path $tool "reports\alpha.config.json"
    Assert-That "-ConfigPath wins" ((Resolve-ValidationConfigPath -ToolRoot $tool -ConfigPath $explicit -Report "beta") -eq $explicit)
    Assert-That "the project ships the example config" ((Resolve-ValidationConfigPath -ToolRoot $projectRoot -Report "example") -like "*\reports\example.config.json")

    # --- Email content
    $mail = New-ValidationEmailContent -Compare $plain -Config $config -RefreshSummary $null -RunFolder $temp -StartedAt (Get-Date).AddHours(-3) -EndedAt (Get-Date)
    Assert-That "email has no em dash" (-not ($mail.HtmlBody.Contains([string][char]0x2014) -or $mail.HtmlBody.Contains("&mdash;")))
    Assert-That "example email has no INFO" (-not ($mail.HtmlBody -match '>INFO</span>'))
    # New-Snapshot: 14 months of 300000 + 1000*i, so the sales total is 4,291,000.00.
    Assert-That "monthly check shows its total" ($mail.HtmlBody -match '4,291,000\.00' -and $mail.HtmlBody -match 'Total of 14 months')
    $shiftMail = New-ValidationEmailContent -Compare $shift -Config $config -RefreshSummary $null -RunFolder $temp -StartedAt (Get-Date).AddHours(-3) -EndedAt (Get-Date)
    Assert-That "new month left out of the total" ($shiftMail.HtmlBody -match 'Total of 13 months, 1 new month\(s\) not in the total')
    Assert-That "config note is read as UTF-8" ($config.emailNote.Contains([string][char]0x0421) -and -not $config.emailNote.Contains([string][char]0x0451)) $config.emailNote
    Assert-That "email shows the config note" ($mail.HtmlBody.Contains($config.emailNote))
    Assert-That "email declares UTF-8" ($mail.HtmlBody -match '<meta charset="utf-8">')
    $infoMail = New-ValidationEmailContent -Compare $same -Config $infoConfig -RefreshSummary $null -RunFolder $temp -StartedAt (Get-Date).AddHours(-3) -EndedAt (Get-Date)
    Assert-That "info check shown as INFO" ($infoMail.HtmlBody -match '>INFO</span>')
    Assert-That "subject counts exclude INFO" ($infoMail.Subject -like "*4/4 checks passed") $infoMail.Subject
    $emptyCompare = [pscustomobject]@{ overall = "FAIL"; counts = [pscustomobject]@{ total = 0; pass = 0; warn = 0; fail = 0; info = 0 }; checks = @() }
    $fatalMail = New-ValidationEmailContent -Compare $emptyCompare -Config $config -RefreshSummary $null -RunFolder $temp -StartedAt (Get-Date) -EndedAt (Get-Date) -FatalError "Pre-check failed <x>"
    Assert-That "fatal subject" ($fatalMail.Subject -like "*run did not complete") $fatalMail.Subject
    Assert-That "fatal banner is encoded" ($fatalMail.HtmlBody -match 'Pre-check failed &lt;x&gt;')
    Assert-That "fatal email has no structure section" (-not ($fatalMail.HtmlBody -match 'Model structure'))

    # --- Model structure: compared for reading only, never part of the verdict
    function New-Structure {
        param([string[]]$Tables, [string[]]$Columns, [string[]]$Measures, [string[]]$Relationships, [string]$MeasureError = "")
        $measurePart = if ($MeasureError) { [pscustomobject]@{ id = "measures"; label = "Measures"; status = "Error"; error = $MeasureError; items = @() } } else { [pscustomobject]@{ id = "measures"; label = "Measures"; status = "Ok"; error = ""; items = $Measures } }
        @(
            [pscustomobject]@{ id = "tables"; label = "Tables"; status = "Ok"; error = ""; items = $Tables },
            [pscustomobject]@{ id = "columns"; label = "Columns"; status = "Ok"; error = ""; items = $Columns },
            $measurePart,
            [pscustomobject]@{ id = "relationships"; label = "Relationships"; status = "Ok"; error = ""; items = $Relationships }
        )
    }
    Assert-That "structure queries use INFO.VIEW only" (@($script:ValidationStructureParts | Where-Object { $_.query -notmatch 'INFO\.VIEW\.' }).Count -eq 0)
    $sBefore = Copy-Object $base
    $sBefore | Add-Member -NotePropertyName structure -NotePropertyValue (New-Structure -Tables @("Calendar", "Fact") -Columns @("'Fact'[A]", "'Fact'[B]") -Measures @("Old measure", "Sales") -Relationships @("'Fact'[D] *[<-]1 'Calendar'[Date]"))
    $sAfter = Copy-Object $base
    $sAfter | Add-Member -NotePropertyName structure -NotePropertyValue (New-Structure -Tables @("Calendar", "Fact") -Columns @("'Fact'[A]", "'Fact'[B]", "'Fact'[C <new>]") -Measures @("Sales", "sales") -Relationships @("'Fact'[D] *[<-]1 'Calendar'[Date]"))
    $sCompare = Compare-ValidationSnapshots -Before $sBefore -After $sAfter -Config $config
    $sColumns = @($sCompare.structure | Where-Object { $_.id -eq "columns" })[0]
    $sMeasures = @($sCompare.structure | Where-Object { $_.id -eq "measures" })[0]
    Assert-That "structure lists the added column" ($sColumns.before -eq 2 -and $sColumns.after -eq 3 -and @($sColumns.added) -contains "'Fact'[C <new>]" -and @($sColumns.removed).Count -eq 0)
    Assert-That "structure lists removed and case-renamed measures" ((@($sMeasures.removed) -contains "Old measure") -and (@($sMeasures.added) -ccontains "sales") -and @($sMeasures.added).Count -eq 1) "added=$(@($sMeasures.added) -join '|') removed=$(@($sMeasures.removed) -join '|')"
    Assert-That "structure change does not touch the verdict" ($sCompare.overall -eq "PASS" -and $sCompare.counts.total -eq 4)
    $sMail = New-ValidationEmailContent -Compare $sCompare -Config $config -RefreshSummary $null -RunFolder $temp -StartedAt (Get-Date).AddHours(-3) -EndedAt (Get-Date)
    Assert-That "email shows the structure section" ($sMail.HtmlBody -match 'Model structure' -and $sMail.HtmlBody -match 'Added columns:</strong> &#39;Fact&#39;\[C &lt;new&gt;\]' -and $sMail.HtmlBody -match 'Removed measures:</strong> Old measure')
    Assert-That "structure change is shown as +1" ($sMail.HtmlBody -match '>\+1</td>')
    $sSame = Compare-ValidationSnapshots -Before $sBefore -After (Copy-Object $sBefore) -Config $config
    Assert-That "unchanged structure says so" ((New-ValidationEmailContent -Compare $sSame -Config $config -RefreshSummary $null -RunFolder $temp -StartedAt (Get-Date) -EndedAt (Get-Date)).HtmlBody -match 'No tables, columns, measures or relationships were added or removed')
    $sOld = Compare-ValidationSnapshots -Before $base -After $sAfter -Config $config
    $sOldTables = @($sOld.structure | Where-Object { $_.id -eq "tables" })[0]
    Assert-That "old baseline without structure: after only" ($null -eq $sOldTables.before -and $sOldTables.after -eq 2 -and @($sOldTables.added).Count -eq 0)
    $sError = Copy-Object $sAfter
    $sError.structure = New-Structure -Tables @("Calendar", "Fact") -Columns @("'Fact'[A]") -Measures @() -Relationships @() -MeasureError "(400) Bad Request"
    $sErrorCompare = Compare-ValidationSnapshots -Before $sBefore -After $sError -Config $config
    $sErrorMail = New-ValidationEmailContent -Compare $sErrorCompare -Config $config -RefreshSummary $null -RunFolder $temp -StartedAt (Get-Date) -EndedAt (Get-Date)
    Assert-That "structure query error is shown, verdict unchanged" ($sErrorCompare.overall -eq "PASS" -and $sErrorMail.HtmlBody -match 'Measures could not be read \(after: \(400\) Bad Request\)')
    Assert-That "no structure in either snapshot: no section" (@($same.structure).Count -eq 0 -and -not ($mail.HtmlBody -match 'Model structure'))

    # --- Safe text
    $safe = Get-ValidationSafeText "Authorization: Bearer abc.def.ghi failed`r`nnext https://x/y?sp=1&sig=SECRETVALUE&a=b"
    Assert-That "safe text removes secrets" (-not ($safe -match 'abc\.def|SECRETVALUE') -and -not $safe.Contains("`n")) $safe
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}

$script:results | Format-Table -AutoSize -Wrap
$failures = @($script:results | Where-Object { -not $_.Ok })
"{0} passed, {1} failed" -f ($script:results.Count - $failures.Count), $failures.Count
if ($failures.Count -gt 0) { throw "Validation logic tests failed." }
"VALIDATION_LOGIC_OK"
