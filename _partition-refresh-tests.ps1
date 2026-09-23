$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "partition-refresh.ps1")

function Assert($Condition, $Message) {
    if (-not $Condition) { throw $Message }
}

$valid = Get-PartitionRefreshRequest ([pscustomobject]@{
    WorkspaceId = "00000000-0000-0000-0000-000000000001"
    DatasetId = "00000000-0000-0000-0000-000000000002"
    TableName = " Sales Fact "
    Partitions = @("2019", " 2020 ")
})
Assert $valid.Ok "Valid request was rejected"
$json = $valid.Payload | ConvertTo-Json -Depth 10 -Compress
Assert ($json -match '"type":"full"') "type must be full"
Assert ($json -match '"commitMode":"transactional"') "commitMode must be transactional"
Assert ($json -match '"applyRefreshPolicy":false') "applyRefreshPolicy must be Boolean false"
Assert ($json -notmatch 'notifyOption') "notifyOption must be absent"
Assert ($valid.TableName -eq " Sales Fact ") "Table name was transformed"
Assert ($valid.Partitions[1] -eq " 2020 ") "Partition name was transformed"

$badWorkspace = Get-PartitionRefreshRequest ([pscustomobject]@{ WorkspaceId = "bad"; DatasetId = [Guid]::NewGuid(); TableName = "T"; Partitions = @("P") })
Assert (-not $badWorkspace.Ok) "Malformed workspace GUID was accepted"
$blankPartition = Get-PartitionRefreshRequest ([pscustomobject]@{ WorkspaceId = [Guid]::NewGuid(); DatasetId = [Guid]::NewGuid(); TableName = "T"; Partitions = @("P", " ") })
Assert (-not $blankPartition.Ok) "Blank partition was accepted"
$duplicatePartition = Get-PartitionRefreshRequest ([pscustomobject]@{ WorkspaceId = [Guid]::NewGuid(); DatasetId = [Guid]::NewGuid(); TableName = "T"; Partitions = @("P", "p") })
Assert (-not $duplicatePartition.Ok) "Duplicate partition was accepted"

$serverSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot "server.ps1") -Raw
Assert ($serverSource -match '"\^/api/partition-refresh/start\$"') "Start route is missing"
Assert ($serverSource -match '"\^/api/partition-refresh/status\$"') "Status route is missing"
Assert ($serverSource -match '"\^/api/partition-refresh/history\$"') "History route is missing"
Assert ($serverSource -match '\$global:partitionSubmissionInProgress') "Submission lock is missing"
$remotePosts = [regex]::Matches($serverSource, 'Invoke-WebRequest[^\r\n]+-Method POST')
Assert ($remotePosts.Count -eq 1) "Expected exactly one remote partition-refresh POST call"
$statusBlock = [regex]::Match($serverSource, '(?s)"\^/api/partition-refresh/status\$".*?"\^/api/partition-refresh/history\$"').Value
$historyBlock = [regex]::Match($serverSource, '(?s)"\^/api/partition-refresh/history\$".*?# ={20,}\r?\n\s*# REBIND').Value
Assert ($statusBlock -match 'Invoke-RestMethod -Method GET') "Status route must use GET"
Assert ($statusBlock -notmatch '-Method POST') "Status route must not use POST"
Assert ($historyBlock -match 'Invoke-RestMethod -Method GET') "History route must use GET"
Assert ($historyBlock -notmatch '-Method POST') "History route must not use POST"

Write-Host "Partition refresh contract tests OK"
