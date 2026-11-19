# Tests the baseline selector with fabricated run folders. Touches only a temp
# directory and removes it afterwards. Sends nothing.
# ASCII only so Windows PowerShell 5.1 reads it correctly.

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $PSScriptRoot) "validation.ps1")

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("validation-baseline-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)

function New-FakeRun {
    param([string]$Root, [string]$Name, [string]$RefreshResult, [string]$WorkspaceName, [string]$ReportName)
    $folder = Join-Path $Root $Name
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $summary = [pscustomobject]@{ workspaceName = $WorkspaceName; reportName = $ReportName; refreshResult = $RefreshResult } | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path $folder "validation-summary.json"), $summary, $utf8)
    $after = [pscustomobject]@{ capturedAt = $Name; checks = @() } | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText((Join-Path $folder "after.json"), $after, $utf8)
    return $folder
}

try {
    New-FakeRun -Root $temp -Name "20260101-000000-aaaa" -RefreshResult "Succeeded" -WorkspaceName "WS" -ReportName "Report X" | Out-Null
    New-FakeRun -Root $temp -Name "20260102-000000-bbbb" -RefreshResult "Failed" -WorkspaceName "WS" -ReportName "Report X" | Out-Null
    New-FakeRun -Root $temp -Name "20260103-000000-cccc" -RefreshResult "Succeeded" -WorkspaceName "WS" -ReportName "Report X" | Out-Null
    New-FakeRun -Root $temp -Name "20260104-000000-dddd" -RefreshResult "Succeeded" -WorkspaceName "WS" -ReportName "Report Y" | Out-Null

    $one = Resolve-ValidationBaseline -RunsRoot $temp -RunsBack 1 -WorkspaceName "WS" -ReportName "Report X"
    $two = Resolve-ValidationBaseline -RunsRoot $temp -RunsBack 2 -WorkspaceName "WS" -ReportName "Report X"
    $other = Resolve-ValidationBaseline -RunsRoot $temp -RunsBack 1 -WorkspaceName "WS" -ReportName "Report Y"

    $results = @(
        [pscustomobject]@{ Requested = "1 back, Report X"; Picked = $one.Folder.Name; Expected = "20260103-000000-cccc"; Ok = ($one.Folder.Name -eq "20260103-000000-cccc") },
        [pscustomobject]@{ Requested = "2 back, Report X"; Picked = $two.Folder.Name; Expected = "20260101-000000-aaaa"; Ok = ($two.Folder.Name -eq "20260101-000000-aaaa") },
        [pscustomobject]@{ Requested = "1 back, Report Y"; Picked = $other.Folder.Name; Expected = "20260104-000000-dddd"; Ok = ($other.Folder.Name -eq "20260104-000000-dddd") }
    )

    $tooFar = ""
    try { Resolve-ValidationBaseline -RunsRoot $temp -RunsBack 3 -WorkspaceName "WS" -ReportName "Report X" | Out-Null } catch { $tooFar = $_.Exception.Message }
    $results += [pscustomobject]@{ Requested = "3 back, Report X"; Picked = $tooFar; Expected = "clear error"; Ok = ($tooFar -like "*Only 2 previous usable run*") }

    $key = Get-ValidationReportKey -WorkspaceName "Contoso TEST" -ReportName "Sales Dashboard"
    $results += [pscustomobject]@{ Requested = "report key"; Picked = $key; Expected = "Contoso TEST - Sales Dashboard"; Ok = ($key -eq "Contoso TEST - Sales Dashboard") }

    $results | Format-Table -AutoSize
    if (@($results | Where-Object { -not $_.Ok }).Count -gt 0) { throw "Baseline selector test failed." }
    "BASELINE_SELECTOR_OK"
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
