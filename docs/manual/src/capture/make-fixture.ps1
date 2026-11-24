<#
.SYNOPSIS
    Creates the fictional PBIP project "SalesOverview" that the manual's Rebind screenshots use.

.DESCRIPTION
    The project points at a fictional DEV workspace and dataflow. All IDs use the
    00000000-0000-0000-0000-* placeholder form, so release-check.ps1 accepts them.
    An existing SalesOverview folder under -Root is deleted and rebuilt.
    ASCII only (Windows PowerShell 5.1 reads scripts without a BOM as ANSI).
#>
param([Parameter(Mandatory = $true)][string]$Root)

$ErrorActionPreference = "Stop"
$devWorkspace = "00000000-0000-0000-0000-0000000000d1"
$devDataflow = "00000000-0000-0000-0000-0000000000d2"

$project = Join-Path $Root "SalesOverview"
if (Test-Path -LiteralPath $project) { Remove-Item -LiteralPath $project -Recurse -Force }
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-FixtureFile([string]$RelativePath, [string]$Text) {
    $path = Join-Path $project $RelativePath
    $folder = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    [System.IO.File]::WriteAllText($path, ($Text -replace "`r?`n", "`r`n"), $utf8NoBom)
}

function Get-DataflowSource([string]$Entity) {
    $t = "`t"
    return @"
${t}${t}${t}let
${t}${t}${t}${t}Source = PowerPlatform.Dataflows(null),
${t}${t}${t}${t}Workspaces = Source{[Id="Workspaces"]}[Data],
${t}${t}${t}${t}Workspace = Workspaces{[workspaceId="$devWorkspace"]}[Data],
${t}${t}${t}${t}Dataflow = Workspace{[dataflowId="$devDataflow"]}[Data],
${t}${t}${t}${t}$Entity = Dataflow{[entity="$Entity",version=""]}[Data]
${t}${t}${t}in
${t}${t}${t}${t}$Entity
"@
}

Write-FixtureFile "SalesOverview.pbip" '{"version":"1.0","artifacts":[{"report":{"path":"SalesOverview.Report"}}],"settings":{"enableAutoRecovery":true}}'
Write-FixtureFile "SalesOverview.Report\definition.pbir" '{"version":"4.0","datasetReference":{"byPath":{"path":"../SalesOverview.SemanticModel"}}}'
Write-FixtureFile "SalesOverview.SemanticModel\definition.pbism" '{"version":"4.2","settings":{}}'
Write-FixtureFile "SalesOverview.SemanticModel\.pbi\localSettings.json" ('{"version":"1.0","remoteModelingObjectId":"' + $devWorkspace + '"}')

foreach ($table in @("Sales", "Customers")) {
    $t = "`t"
    $text = "table $table`n`n${t}column Id`n${t}${t}dataType: int64`n${t}${t}sourceColumn: Id`n`n" +
        "${t}partition $table = m`n${t}${t}mode: import`n${t}${t}source =`n" + (Get-DataflowSource $table) + "`n"
    Write-FixtureFile "SalesOverview.SemanticModel\definition\tables\$table.tmdl" $text
}

$t = "`t"
Write-FixtureFile "SalesOverview.SemanticModel\definition\expressions.tmdl" (
    "expression DataflowWorkspace = `"$devWorkspace`" meta [IsParameterQuery=true, Type=`"Text`", IsParameterQueryRequired=true]`n" +
    "${t}lineageTag: 00000000-0000-0000-0000-0000000000f1`n`n" +
    "expression DataflowId = `"$devDataflow`" meta [IsParameterQuery=true, Type=`"Text`", IsParameterQueryRequired=true]`n" +
    "${t}lineageTag: 00000000-0000-0000-0000-0000000000f2`n")

Write-Host "Fixture ready: $project"
