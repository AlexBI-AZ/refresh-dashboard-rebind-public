# Read-only catalog for the Control Panel's name pickers: workspaces, the reports,
# semantic models and dataflows in a workspace, a semantic model's upstream dataflows
# (lineage), and names for IDs a profile already holds. Every call is a GET against the
# Power BI REST API; nothing here starts or changes anything.
#
# server.ps1 dot-sources this file and calls Initialize-RefreshCatalog with its own
# token before each request. The tests dot-source it and replace Invoke-PowerBiRequest
# with a fake service.
#
# Windows PowerShell 5.1. Keep this file ASCII-only.

. (Join-Path $PSScriptRoot "refresh-engine.ps1")

function Initialize-RefreshCatalog {
    # Uses the caller's token, keeps the console quiet, and forgets cached names, so a
    # renamed workspace or item shows its new name on the next lookup.
    param([Parameter(Mandatory = $true)][string]$Token)

    $script:RefreshQuiet = $true
    $script:RefreshLogFile = $null
    $script:RefreshStatusFile = $null
    $script:RefreshWorkspaceNames = @{}
    Initialize-RefreshAuthorization -InitialToken $Token
}

function Test-RefreshCatalogGuid {
    param([AllowNull()][string]$Value)

    $parsed = [Guid]::Empty
    return [Guid]::TryParse([string]$Value, [ref]$parsed)
}

function Get-RefreshCatalogName {
    # A display name, or the placeholder; never the raw ID.
    param([AllowNull()][object]$Value, [Parameter(Mandatory = $true)][string]$Fallback)

    $text = ([string]$Value).Trim()
    if ($text) { return $text }
    return $Fallback
}

function Get-RefreshCatalogWorkspaces {
    # Every workspace the signed-in identity can open, sorted by name.
    $groups = @((Invoke-PowerBiRequest -Method GET -Uri "$script:PowerBiApi/groups").value)
    return @(
        $groups |
            Where-Object { $_ -and $_.id } |
            ForEach-Object { [pscustomobject][ordered]@{ id = [string]$_.id; name = (Get-RefreshCatalogName $_.name "Unnamed workspace") } } |
            Sort-Object name
    )
}

function Get-RefreshCatalogWorkspaceItems {
    # Reports, semantic models and dataflows in one workspace. A list that cannot be read
    # (for example no access to dataflows) is left empty with a warning; the others
    # still come back. An authorization error is not hidden.
    param([Parameter(Mandatory = $true)][string]$WorkspaceId)

    Assert-RefreshGuid $WorkspaceId "The workspace"
    $warnings = @()
    $reports = @()
    $models = @()
    $dataflows = @()

    try {
        $reports = @(
            @((Invoke-PowerBiRequest -Method GET -Uri "$script:PowerBiApi/groups/$WorkspaceId/reports").value) |
                Where-Object { $_ -and $_.id } |
                ForEach-Object {
                    $modelWorkspaceId = if ($_.datasetWorkspaceId) { [string]$_.datasetWorkspaceId } else { $WorkspaceId }
                    [pscustomobject][ordered]@{
                        id = [string]$_.id
                        name = (Get-RefreshCatalogName $_.name "Unnamed report")
                        datasetId = [string]$_.datasetId
                        datasetWorkspaceId = $modelWorkspaceId
                    }
                } |
                Sort-Object name
        )
    } catch {
        if (Test-RefreshAuthorizationError $_) { throw }
        $warnings += "Reports could not be read: $(Get-RefreshShortError $_)"
    }

    try {
        $models = @(
            @((Invoke-PowerBiRequest -Method GET -Uri "$script:PowerBiApi/groups/$WorkspaceId/datasets").value) |
                Where-Object { $_ -and $_.id } |
                ForEach-Object {
                    $refreshable = if (@($_.PSObject.Properties.Name) -contains "isRefreshable") { [bool]$_.isRefreshable } else { $true }
                    [pscustomobject][ordered]@{
                        id = [string]$_.id
                        name = (Get-RefreshCatalogName $_.name "Unnamed semantic model")
                        isRefreshable = $refreshable
                    }
                } |
                Sort-Object name
        )
    } catch {
        if (Test-RefreshAuthorizationError $_) { throw }
        $warnings += "Semantic models could not be read: $(Get-RefreshShortError $_)"
    }

    try {
        # The dataflows list names its key objectId, not id.
        $dataflows = @(
            @((Invoke-PowerBiRequest -Method GET -Uri "$script:PowerBiApi/groups/$WorkspaceId/dataflows").value) |
                Where-Object { $_ -and ($_.objectId -or $_.id) } |
                ForEach-Object {
                    $dataflowId = if ($_.objectId) { [string]$_.objectId } else { [string]$_.id }
                    [pscustomobject][ordered]@{ id = $dataflowId; name = (Get-RefreshCatalogName $_.name "Unnamed dataflow") }
                } |
                Sort-Object name
        )
    } catch {
        if (Test-RefreshAuthorizationError $_) { throw }
        $warnings += "Dataflows could not be read: $(Get-RefreshShortError $_)"
    }

    return [pscustomobject][ordered]@{
        reports = @($reports)
        semanticModels = @($models)
        dataflows = @($dataflows)
        warnings = @($warnings)
    }
}

function Get-RefreshCatalogUpstream {
    # A semantic model and the dataflows it reads from (lineage), with names. The
    # dataflows may live in other workspaces; each carries its own. When lineage cannot
    # be read the list is empty with a warning, so the user can still add dataflows by hand.
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceId,
        [Parameter(Mandatory = $true)][string]$DatasetId
    )

    Assert-RefreshGuid $WorkspaceId "The semantic model workspace"
    Assert-RefreshGuid $DatasetId "The semantic model"
    $model = Invoke-PowerBiRequest -Method GET -Uri "$script:PowerBiApi/groups/$WorkspaceId/datasets/$DatasetId"
    $refreshable = if ($model -and @($model.PSObject.Properties.Name) -contains "isRefreshable") { [bool]$model.isRefreshable } else { $true }
    $modelView = [pscustomobject][ordered]@{
        id = $DatasetId
        name = (Get-RefreshCatalogName $model.name "Unnamed semantic model")
        workspaceId = $WorkspaceId
        workspaceName = (Get-RefreshWorkspaceLabel $WorkspaceId)
        isRefreshable = $refreshable
    }

    $warnings = @()
    $links = @()
    try {
        $links = @(Get-RefreshUpstreamDataflowLinks -LineageWorkspaceId $WorkspaceId -DatasetId $DatasetId -Model $model)
    } catch {
        if (Test-RefreshAuthorizationError $_) { throw }
        $warnings += "Dataflow lineage could not be read for this semantic model; add its dataflows by hand."
    }

    $dataflows = @(
        foreach ($link in $links) {
            [pscustomobject][ordered]@{
                id = [string]$link.DataflowId
                name = (Get-RefreshItemLabel $link.WorkspaceId $link.DataflowId "dataflows")
                workspaceId = [string]$link.WorkspaceId
                workspaceName = (Get-RefreshWorkspaceLabel $link.WorkspaceId)
            }
        }
    )
    return [pscustomobject][ordered]@{ model = $modelView; dataflows = @($dataflows); warnings = @($warnings) }
}

function Resolve-RefreshCatalogNames {
    # Names for the IDs a saved profile holds, so profiles saved before the pickers show
    # names. Entries that are not GUIDs are skipped; an unreadable item gets a
    # placeholder, never its ID. At most 100 entries per list.
    param(
        [AllowNull()][object[]]$WorkspaceIds,
        [AllowNull()][object[]]$Dataflows,
        [AllowNull()][object[]]$SemanticModels
    )

    $workspaces = @(
        @($WorkspaceIds) | Where-Object { Test-RefreshCatalogGuid ([string]$_) } | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Select-Object -Unique -First 100 |
            ForEach-Object { [pscustomobject][ordered]@{ id = $_; name = (Get-RefreshWorkspaceLabel $_) } }
    )
    $resolveItems = {
        param([object[]]$Entries, [string]$Collection)
        @(
            @($Entries) |
                Where-Object { $_ -and (Test-RefreshCatalogGuid ([string]$_.workspaceId)) -and (Test-RefreshCatalogGuid ([string]$_.id)) } |
                Select-Object -First 100 |
                ForEach-Object {
                    $itemWorkspaceId = ([string]$_.workspaceId).Trim()
                    $itemId = ([string]$_.id).Trim()
                    [pscustomobject][ordered]@{
                        workspaceId = $itemWorkspaceId
                        id = $itemId
                        name = (Get-RefreshItemLabel $itemWorkspaceId $itemId $Collection)
                        workspaceName = (Get-RefreshWorkspaceLabel $itemWorkspaceId)
                    }
                }
        )
    }
    return [pscustomobject][ordered]@{
        workspaces = @($workspaces)
        dataflows = @(& $resolveItems $Dataflows "dataflows")
        semanticModels = @(& $resolveItems $SemanticModels "datasets")
    }
}
