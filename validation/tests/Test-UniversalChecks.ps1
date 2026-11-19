# Offline tests for the universal checks that every model gets when no report config
# matches it: the table list and its skip rules, the rows-per-table comparison, the
# email section, and how a report config is found. No network, sends nothing.
# ASCII only so Windows PowerShell 5.1 reads it correctly.

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot "validation.ps1")

$script:results = @()
function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = "")
    $script:results += [pscustomobject]@{ Ok = $Condition; Test = $Name; Detail = $Detail }
}

# executeQueries answered from memory. Every query is recorded.
$script:Queries = New-Object System.Collections.Generic.List[string]
$script:Counts = @{}
function Invoke-ValidationQuery {
    param([string]$WorkspaceId, [string]$DatasetId, [hashtable]$Headers, [string]$Query)
    $script:Queries.Add($Query)
    if ($Query -like '*INFO.VIEW.TABLES()*"IsPrivate"*') {
        return @(
            [pscustomobject]@{ "[Name]" = "Sales"; "[IsPrivate]" = $false; "[StorageMode]" = "Import"; "[CalculationGroupPrecedence]" = $null },
            [pscustomobject]@{ "[Name]" = "O'Brien ""list"""; "[IsPrivate]" = $false; "[StorageMode]" = "Dual"; "[CalculationGroupPrecedence]" = $null },
            [pscustomobject]@{ "[Name]" = "Empty"; "[IsPrivate]" = $false; "[StorageMode]" = "Import"; "[CalculationGroupPrecedence]" = $null },
            [pscustomobject]@{ "[Name]" = "LocalDateTable_1"; "[IsPrivate]" = $false; "[StorageMode]" = "Import"; "[CalculationGroupPrecedence]" = $null },
            [pscustomobject]@{ "[Name]" = "DateTableTemplate_1"; "[IsPrivate]" = $true; "[StorageMode]" = "Import"; "[CalculationGroupPrecedence]" = $null },
            [pscustomobject]@{ "[Name]" = "Hidden"; "[IsPrivate]" = $true; "[StorageMode]" = "Import"; "[CalculationGroupPrecedence]" = $null },
            [pscustomobject]@{ "[Name]" = "Time intelligence"; "[IsPrivate]" = $false; "[StorageMode]" = "Import"; "[CalculationGroupPrecedence]" = 0 },
            [pscustomobject]@{ "[Name]" = "Live"; "[IsPrivate]" = $false; "[StorageMode]" = "DirectQuery"; "[CalculationGroupPrecedence]" = $null },
            [pscustomobject]@{ "[Name]" = "Measures"; "[IsPrivate]" = $false; "[StorageMode]" = "Import"; "[CalculationGroupPrecedence]" = $null })
    }
    if ($Query -like '*INFO.VIEW.COLUMNS()*"Table", `[Table`]*') {
        # "Measures" has no columns; the skipped tables do.
        return @("Sales", "Sales", "O'Brien ""list""", "Empty", "LocalDateTable_1", "Hidden", "Time intelligence", "Live" | ForEach-Object { [pscustomobject]@{ "[Table]" = $_ } })
    }
    if ($Query -like 'EVALUATE UNION(*') {
        return @(
            [pscustomobject]@{ "[Table]" = "Sales"; "[Rows]" = 1200 },
            [pscustomobject]@{ "[Table]" = "O'Brien ""list"""; "[Rows]" = 7 },
            [pscustomobject]@{ "[Table]" = "Empty"; "[Rows]" = $null })
    }
    throw "Unexpected query: $Query"
}

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("validation-universal-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path (Join-Path $temp "reports") -Force | Out-Null
try {
    # --- Universal config
    $config = New-ValidationUniversalConfig -WorkspaceName "Sales TEST" -ModelName "Sales Model" -ToolRoot $projectRoot
    Assert-That "universal config fills the names" ($config.workspaceName -eq "Sales TEST" -and $config.reportName -eq "Sales Model" -and $config.semanticModelName -eq "Sales Model" -and $config.universal -eq $true)
    Assert-That "universal config counts rows per table and compares structure" ((@($config.checks | ForEach-Object { $_.kind }) -join ",") -eq "table_rows" -and [bool]$config.modelStructure)
    $withReport = New-ValidationUniversalConfig -WorkspaceName "Sales TEST" -ReportName "Sales Report" -ModelName "Sales Model" -ToolRoot $projectRoot
    Assert-That "universal config prefers the report name" ($withReport.reportName -eq "Sales Report")
    $note = [System.IO.File]::ReadAllText((Join-Path $projectRoot "universal-checks.json"), [System.Text.Encoding]::UTF8)
    Assert-That "universal-checks.json has no yo and no em dash" (-not ($note.Contains([string][char]0x0451) -or $note.Contains([string][char]0x0401) -or $note.Contains([string][char]0x2014)))

    # --- Table list and row counts
    $target = [pscustomobject]@{ modelWorkspaceId = "ws"; datasetId = "ds" }
    $rows = @(Get-ValidationTableRows -Target $target -Headers @{})
    Assert-That "only counted tables are returned, sorted" ((@($rows | ForEach-Object { $_.key }) -join "|") -eq "Empty|O'Brien ""list""|Sales") (@($rows | ForEach-Object { $_.key }) -join "|")
    Assert-That "a blank COUNTROWS is zero rows" (@($rows | Where-Object { $_.key -eq "Empty" })[0].value -eq 0)
    $union = @($script:Queries | Where-Object { $_ -like 'EVALUATE UNION(*' })[0]
    Assert-That "table names are quoted for DAX" ($union.Contains("COUNTROWS('O''Brien ""list""')") -and $union.Contains('"O''Brien ""list"""')) $union
    Assert-That "skipped tables are never counted" (-not ($union -match "LocalDateTable|DateTableTemplate|Hidden|Time intelligence|Live|'Measures'")) $union
    Assert-That "three queries read the counts" ($script:Queries.Count -eq 3)

    # --- Comparison
    $universal = New-ValidationUniversalConfig -WorkspaceName "Sales TEST" -ModelName "Sales Model" -ToolRoot $projectRoot
    $universal.modelStructure = $false
    function New-RowsSnapshot {
        param([hashtable]$Counts)
        $values = @($Counts.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ key = $_; value = $Counts[$_] } })
        return [pscustomobject]@{ capturedAt = (Get-Date).ToString("o"); workspaceName = "Sales TEST"; reportName = "Sales Model"
            checks = @([pscustomobject]@{ id = "rows_per_table"; label = "Rows per table"; kind = "table_rows"; status = "Ok"; error = ""; value = $null; values = $values; rowCount = $values.Count }) }
    }
    $before = New-RowsSnapshot @{ Same = 500; Grew = 100; Warned = 100; Failed = 100; Emptied = 40; Gone = 5; WasEmpty = 0 }
    $after = New-RowsSnapshot @{ Same = 500; Grew = 105; Warned = 115; Failed = 70; Emptied = 0; Added = 3; WasEmpty = 9 }
    $compare = Compare-ValidationSnapshots -Before $before -After $after -Config $universal
    $check = @($compare.checks)[0]
    $byKey = @{}; foreach ($row in @($check.months)) { $byKey[$row.key] = $row }
    Assert-That "unchanged and small changes pass" ($byKey["Same"].verdict -eq "PASS" -and $byKey["Grew"].verdict -eq "PASS")
    Assert-That "a 15% change warns" ($byKey["Warned"].verdict -eq "WARN")
    Assert-That "a 30% drop fails" ($byKey["Failed"].verdict -eq "FAIL")
    Assert-That "a table that comes back empty fails" ($byKey["Emptied"].verdict -eq "FAIL" -and $byKey["Emptied"].message -eq "No rows after refresh")
    Assert-That "a table no longer counted warns" ($byKey["Gone"].verdict -eq "WARN" -and $byKey["Gone"].message -eq "Table no longer counted")
    Assert-That "a new table passes" ($byKey["Added"].verdict -eq "PASS" -and $byKey["Added"].message -eq "New table")
    Assert-That "a table that was empty passes" ($byKey["WasEmpty"].verdict -eq "PASS" -and $byKey["WasEmpty"].message -eq "Was empty")
    Assert-That "the worst table decides the check" ($check.verdict -eq "FAIL" -and $compare.overall -eq "FAIL")
    Assert-That "totals cover tables counted both times" ($check.before -eq 840 -and $check.after -eq 799) "$($check.before) -> $($check.after)"

    $quiet = Compare-ValidationSnapshots -Before (New-RowsSnapshot @{ A = 10; B = 20 }) -After (New-RowsSnapshot @{ A = 10; B = 21 }) -Config $universal
    Assert-That "small changes give PASS" ($quiet.overall -eq "PASS")

    # --- Email
    $mail = New-ValidationEmailContent -Compare $compare -Config $universal -RunFolder $temp -StartedAt (Get-Date).AddMinutes(-5) -EndedAt (Get-Date)
    Assert-That "the email names the universal checks" ($mail.HtmlBody -match "universal checks for any model" -and $mail.HtmlBody -match "Rows per table")
    Assert-That "the changed tables are listed, the unchanged one counted" ($mail.HtmlBody -match "tables that changed" -and $mail.HtmlBody -match "1 other table\(s\) have the same number of rows")
    Assert-That "the subject carries the verdict" ($mail.Subject -match "Sales Model" -and $mail.Overall -eq "FAIL") $mail.Subject

    # --- Finding a report config
    $writeConfig = {
        param([string]$Name, [hashtable]$Values)
        [System.IO.File]::WriteAllText((Join-Path $temp "reports\$Name"), ($Values | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
    }
    $checks = @(@{ id = "x"; label = "X"; kind = "scalar"; query = "EVALUATE ROW(""V"", 1)"; valueField = "V" })
    & $writeConfig "a-by-model.config.json" @{ workspaceName = "Sales TEST"; reportName = "Sales Report"; semanticModelName = "Sales Model"; checks = $checks }
    & $writeConfig "b-by-report.config.json" @{ workspaceName = "Sales TEST"; reportName = "Old Report"; checks = $checks }
    & $writeConfig "c-other-workspace.config.json" @{ workspaceName = "Sales PROD"; reportName = "Sales Report"; semanticModelName = "Prod Model"; checks = $checks }
    [System.IO.File]::WriteAllText((Join-Path $temp "reports\d-broken.config.json"), "{ not json", (New-Object System.Text.UTF8Encoding $false))

    $found = Find-ValidationConfigForModel -WorkspaceName "sales test" -ModelName "SALES MODEL" -ToolRoot $temp
    Assert-That "a config matches by workspace and model, ignoring case" ($null -ne $found -and $found.configPath -like "*a-by-model.config.json")
    $found = Find-ValidationConfigForModel -WorkspaceName "Sales TEST" -ModelName "Unrelated" -ReportName "Old Report" -ToolRoot $temp
    Assert-That "a config without a model name matches by report name" ($null -ne $found -and $found.configPath -like "*b-by-report.config.json")
    $found = Find-ValidationConfigForModel -WorkspaceName "Sales TEST" -ModelName "Prod Model" -ToolRoot $temp
    Assert-That "a config in another workspace never matches" ($null -eq $found)
    $found = Find-ValidationConfigForModel -WorkspaceName "Sales TEST" -ModelName "Unrelated" -ToolRoot $temp
    Assert-That "no match returns null and a broken file is skipped" ($null -eq $found)
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}

$script:results | Format-Table -AutoSize -Wrap
$failures = @($script:results | Where-Object { -not $_.Ok })
"{0} passed, {1} failed" -f ($script:results.Count - $failures.Count), $failures.Count
if ($failures.Count -gt 0) { throw "Universal check tests failed." }
"UNIVERSAL_CHECKS_OK"
