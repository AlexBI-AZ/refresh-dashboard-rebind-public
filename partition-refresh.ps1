function Get-PartitionRefreshRequest {
    param($Body)

    $workspaceId = [Guid]::Empty
    $datasetId = [Guid]::Empty
    if (-not [Guid]::TryParse([string]$Body.WorkspaceId, [ref]$workspaceId)) {
        return [pscustomobject]@{ Ok = $false; Error = "Workspace ID must be a valid GUID" }
    }
    if (-not [Guid]::TryParse([string]$Body.DatasetId, [ref]$datasetId)) {
        return [pscustomobject]@{ Ok = $false; Error = "Dataset ID must be a valid GUID" }
    }

    $tableName = [string]$Body.TableName
    if ([string]::IsNullOrWhiteSpace($tableName)) {
        return [pscustomobject]@{ Ok = $false; Error = "Table name is required" }
    }

    $partitions = @($Body.Partitions)
    if ($partitions.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Error = "At least one partition is required" }
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $exactPartitions = @()
    foreach ($partitionValue in $partitions) {
        $partition = [string]$partitionValue
        if ([string]::IsNullOrWhiteSpace($partition)) {
            return [pscustomobject]@{ Ok = $false; Error = "Partition names cannot be blank" }
        }
        if (-not $seen.Add($partition)) {
            return [pscustomobject]@{ Ok = $false; Error = "Duplicate partition name: $partition" }
        }
        $exactPartitions += $partition
    }

    $objects = @(
        foreach ($partition in $exactPartitions) {
            [ordered]@{ table = $tableName; partition = $partition }
        }
    )
    $payload = [ordered]@{
        type = "full"
        commitMode = "transactional"
        applyRefreshPolicy = $false
        objects = $objects
    }

    return [pscustomobject]@{
        Ok = $true
        Error = ""
        WorkspaceId = $workspaceId.ToString()
        DatasetId = $datasetId.ToString()
        TableName = $tableName
        Partitions = $exactPartitions
        Payload = $payload
    }
}

function Get-PowerBiRequestId {
    param($WebResponse)

    $location = [string]$WebResponse.Headers["Location"]
    if ($location) {
        $lastSegment = $location.TrimEnd('/').Split('/')[-1]
        $parsed = [Guid]::Empty
        if ([Guid]::TryParse($lastSegment, [ref]$parsed)) { return $parsed.ToString() }
    }
    $headerId = [string]$WebResponse.Headers["x-ms-request-id"]
    if ($headerId) { return $headerId }
    return ""
}

function Test-PartitionRefreshTerminalStatus {
    param($State)
    $status = [string]$State.status
    $extendedStatus = [string]$State.extendedStatus
    return @("Completed", "Failed", "Cancelled", "Disabled") -contains $status -or
        @("Completed", "Failed", "Cancelled", "Disabled") -contains $extendedStatus
}
