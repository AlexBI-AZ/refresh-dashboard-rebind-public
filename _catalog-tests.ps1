# Offline tests for the read-only catalog behind the Refresh tab's name pickers
# (runtime\refresh-catalog.ps1) and for the server's Invoke-CatalogRequest. The Power BI
# service is an in-memory fake: nothing signs in and nothing is changed.

$ErrorActionPreference = "Stop"

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

. (Join-Path $PSScriptRoot "runtime\refresh-catalog.ps1")

# --- fake service ---------------------------------------------------------------------------
$script:Ids = @{}
foreach ($key in @("ws", "ws2", "wsEmpty", "report", "report2", "model", "model2", "df1", "df2", "dfOther")) { $script:Ids[$key] = [Guid]::NewGuid().ToString() }
$script:Fail = @{}
$script:Calls = New-Object System.Collections.Generic.List[string]

function Invoke-PowerBiRequest {
    param([string]$Method, [string]$Uri, [string]$Body)

    $script:Calls.Add("$Method $Uri")
    if ($Method -ne "GET") { throw "The catalog must only read, but sent $Method $Uri" }
    $path = $Uri.Substring("https://api.powerbi.com/v1.0/myorg".Length)
    $ids = $script:Ids
    foreach ($pattern in $script:Fail.Keys) {
        if ($path -match $pattern) { throw $script:Fail[$pattern] }
    }
    if ($path -eq "/groups") {
        return [pscustomobject]@{ value = @(
            [pscustomobject]@{ id = $ids.ws2; name = "Zeta" },
            [pscustomobject]@{ id = $ids.ws; name = "Alpha TEST" },
            [pscustomobject]@{ id = $ids.wsEmpty; name = "" }) }
    }
    if ($path -eq "/groups/$($ids.ws)/reports") {
        return [pscustomobject]@{ value = @(
            [pscustomobject]@{ id = $ids.report2; name = "Sales"; datasetId = $ids.model2; datasetWorkspaceId = $ids.ws2 },
            [pscustomobject]@{ id = $ids.report; name = "Dashboard"; datasetId = $ids.model }) }
    }
    if ($path -eq "/groups/$($ids.ws)/datasets") {
        return [pscustomobject]@{ value = @(
            [pscustomobject]@{ id = $ids.model; name = "Dashboard"; isRefreshable = $true },
            [pscustomobject]@{ id = $ids.model2; name = "Live model"; isRefreshable = $false }) }
    }
    if ($path -eq "/groups/$($ids.ws)/dataflows") {
        return [pscustomobject]@{ value = @(
            [pscustomobject]@{ objectId = $ids.df2; name = "Dictionaries" },
            [pscustomobject]@{ objectId = $ids.df1; name = "Star" }) }
    }
    if ($path -match '^/groups/([^/]+)/datasets/upstreamDataflows$') {
        return [pscustomobject]@{ value = @(
            [pscustomobject]@{ datasetObjectId = $ids.model; workspaceObjectId = $ids.ws; dataflowObjectId = $ids.df1 },
            [pscustomobject]@{ datasetObjectId = $ids.model; workspaceObjectId = $ids.ws2; dataflowObjectId = $ids.dfOther },
            [pscustomobject]@{ datasetObjectId = $ids.model; workspaceObjectId = $ids.ws; dataflowObjectId = $ids.df1 },
            [pscustomobject]@{ datasetObjectId = $ids.model2; workspaceObjectId = $ids.ws; dataflowObjectId = $ids.df2 }) }
    }
    if ($path -eq "/groups/$($ids.ws)/datasets/$($ids.model)") {
        if (-not $script:ModelHasLineage) { return [pscustomobject]@{ id = $ids.model; name = "Dashboard"; isRefreshable = $true } }
        return [pscustomobject]@{ id = $ids.model; name = "Dashboard"; isRefreshable = $true; upstreamDataflows = @([pscustomobject]@{ groupId = $ids.ws; targetDataflowId = $ids.df2 }) }
    }
    if ($path -match '^/groups/([^/]+)$') {
        $map = @{ $ids.ws = "Alpha TEST"; $ids.ws2 = "Zeta" }
        if ($map.ContainsKey($Matches[1])) { return [pscustomobject]@{ name = $map[$Matches[1]] } }
        throw "Response status code does not indicate success: 404 (Not Found)."
    }
    if ($path -match '^/groups/([^/]+)/dataflows/([^/]+)$') {
        $map = @{ $ids.df1 = "Star"; $ids.df2 = "Dictionaries"; $ids.dfOther = "Shared dates" }
        if ($map.ContainsKey($Matches[2])) { return [pscustomobject]@{ name = $map[$Matches[2]] } }
        throw "Response status code does not indicate success: 404 (Not Found)."
    }
    if ($path -match '^/groups/([^/]+)/datasets/([^/]+)$') {
        throw "Response status code does not indicate success: 404 (Not Found)."
    }
    throw "Fake service: unexpected call $Method $path"
}

function Reset-Fake { $script:Fail = @{}; $script:Calls.Clear(); $script:ModelHasLineage = $true }

$checks = 0
Initialize-RefreshCatalog -Token "fake-token"

# 1. Workspaces: sorted by name, an unnamed one gets a placeholder, never its ID.
Reset-Fake
$workspaces = @(Get-RefreshCatalogWorkspaces)
Assert ((@($workspaces | ForEach-Object { $_.name }) -join "|") -eq "Alpha TEST|Unnamed workspace|Zeta") "Workspaces are sorted and named: $(@($workspaces | ForEach-Object { $_.name }) -join '|')"
Assert ((@($workspaces[0].PSObject.Properties.Name) -join ",") -eq "id,name") "A workspace carries id and name"
$checks++

# 2. Items in a workspace: reports with their model's workspace (own or the report's),
#    models with isRefreshable, dataflows keyed by objectId.
Reset-Fake
$items = Get-RefreshCatalogWorkspaceItems -WorkspaceId $script:Ids.ws
Assert ((@($items.reports | ForEach-Object { $_.name }) -join "|") -eq "Dashboard|Sales") "Reports are listed by name"
$dashboard = @($items.reports | Where-Object { $_.name -eq "Dashboard" })[0]
$sales = @($items.reports | Where-Object { $_.name -eq "Sales" })[0]
Assert ($dashboard.datasetWorkspaceId -eq $script:Ids.ws -and $sales.datasetWorkspaceId -eq $script:Ids.ws2) "A report's model workspace defaults to the report's workspace"
Assert ((@($items.semanticModels | Where-Object { -not $_.isRefreshable } | ForEach-Object { $_.name }) -join "|") -eq "Live model") "Models say whether they can be refreshed"
Assert ((@($items.dataflows | ForEach-Object { "$($_.name)=$($_.id)" }) -join "|") -eq "Dictionaries=$($script:Ids.df2)|Star=$($script:Ids.df1)") "Dataflows use objectId as their ID"
Assert (@($items.warnings).Count -eq 0) "No warnings when everything is readable"
$checks++

# 3. One unreadable list leaves a warning; the others still come back.
Reset-Fake
$script:Fail['^/groups/[^/]+/dataflows$'] = "Response status code does not indicate success: 403 (Forbidden)."
$items = Get-RefreshCatalogWorkspaceItems -WorkspaceId $script:Ids.ws
Assert (@($items.dataflows).Count -eq 0 -and @($items.reports).Count -eq 2) "Reports survive an unreadable dataflow list"
Assert (@($items.warnings)[0] -like "Dataflows could not be read*") "The unreadable list is named in a warning"
$checks++

# 4. Upstream: lineage gives the model's dataflows, in any workspace, named, without
#    duplicates and without another model's dataflows.
Reset-Fake
$upstream = Get-RefreshCatalogUpstream -WorkspaceId $script:Ids.ws -DatasetId $script:Ids.model
Assert ($upstream.model.name -eq "Dashboard" -and $upstream.model.workspaceName -eq "Alpha TEST" -and $upstream.model.isRefreshable) "The model is named with its workspace"
Assert ((@($upstream.dataflows | ForEach-Object { "$($_.name)@$($_.workspaceName)" }) -join "|") -eq "Star@Alpha TEST|Shared dates@Zeta") "Upstream dataflows come from lineage, each with its own workspace"
Assert (@($upstream.warnings).Count -eq 0) "No warning when lineage is readable"
$checks++

# 5. Lineage endpoint unreadable: the model's own upstreamDataflows are used.
Reset-Fake
$script:Fail['/datasets/upstreamDataflows$'] = "Response status code does not indicate success: 403 (Forbidden)."
$upstream = Get-RefreshCatalogUpstream -WorkspaceId $script:Ids.ws -DatasetId $script:Ids.model
Assert ((@($upstream.dataflows | ForEach-Object { $_.name }) -join "|") -eq "Dictionaries") "The model's own lineage is the fallback"
$checks++

# 6. No lineage at all (endpoint unreadable, model without its own list): the shared
#    helper still refuses, which the runner relies on, while the catalog returns an
#    empty list with a warning so the user can add dataflows by hand.
Reset-Fake
$script:Fail['/datasets/upstreamDataflows$'] = "Response status code does not indicate success: 403 (Forbidden)."
$script:ModelHasLineage = $false
$helperRefused = $false
try { Get-RefreshUpstreamDataflowLinks -LineageWorkspaceId $script:Ids.ws -DatasetId $script:Ids.model -Model ([pscustomobject]@{ id = $script:Ids.model }) | Out-Null } catch { $helperRefused = $true }
Assert $helperRefused "The shared lineage helper refuses when no lineage exists"
$upstream = Get-RefreshCatalogUpstream -WorkspaceId $script:Ids.ws -DatasetId $script:Ids.model
Assert (@($upstream.dataflows).Count -eq 0 -and @($upstream.warnings)[0] -like "Dataflow lineage could not be read*") "Missing lineage is a warning in the catalog"
$checks++

# 7. Names for saved IDs: placeholders for unreadable items, non-GUIDs skipped, no IDs as names.
Reset-Fake
$names = Resolve-RefreshCatalogNames -WorkspaceIds @($script:Ids.ws, "not-a-guid", $script:Ids.ws.ToUpperInvariant(), [Guid]::NewGuid().ToString()) `
    -Dataflows @([pscustomobject]@{ workspaceId = $script:Ids.ws2; id = $script:Ids.dfOther }, [pscustomobject]@{ workspaceId = $script:Ids.ws; id = [Guid]::NewGuid().ToString() }, [pscustomobject]@{ workspaceId = $script:Ids.ws; id = "" }) `
    -SemanticModels @([pscustomobject]@{ workspaceId = $script:Ids.ws; id = $script:Ids.model })
Assert (@($names.workspaces).Count -eq 2) "Workspaces are deduplicated and non-GUIDs skipped"
Assert ((@($names.workspaces | ForEach-Object { $_.name }) -join "|") -eq "Alpha TEST|Workspace name unavailable") "An unreadable workspace gets a placeholder"
Assert ((@($names.dataflows | ForEach-Object { $_.name }) -join "|") -eq "Shared dates|Unnamed dataflow") "Dataflow names resolve; an unreadable one gets a placeholder; a blank ID is skipped"
Assert (@($names.semanticModels)[0].name -eq "Dashboard" -and @($names.semanticModels)[0].workspaceName -eq "Alpha TEST") "Model names resolve"
$allNames = (@($names.workspaces) + @($names.dataflows) + @($names.semanticModels) | ForEach-Object { $_.name }) -join " "
Assert ($allNames -notmatch '[0-9a-f]{8}-[0-9a-f]{4}-') "No ID is ever shown as a name"
$checks++

# 8. An authorization error is not swallowed.
Reset-Fake
$script:Fail['^/groups/[^/]+/reports$'] = "Power BI rejected authorization even after silent renewal."
$threw = $false
try { Get-RefreshCatalogWorkspaceItems -WorkspaceId $script:Ids.ws | Out-Null } catch { $threw = $_.Exception.Message -like "Power BI rejected authorization*" }
Assert $threw "An authorization error reaches the caller"
$checks++

# --- the server's Invoke-CatalogRequest ------------------------------------------------------
$serverSource = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "server.ps1"))
$serverAst = [System.Management.Automation.Language.Parser]::ParseInput($serverSource, [ref]$null, [ref]$null)
$functionAst = $serverAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Invoke-CatalogRequest" }, $true)
Assert ($null -ne $functionAst) "server.ps1 defines Invoke-CatalogRequest"
Invoke-Expression $functionAst.Extent.Text
$global:catalogWorkspaceCache = $null

# 9. Routing, methods and argument checks.
Reset-Fake
Assert ((Invoke-CatalogRequest -Path "/api/catalog/nothing" -Method GET -Query @{} -Token "t").Status -eq 404) "An unknown catalog path is 404"
Assert ((Invoke-CatalogRequest -Path "/api/catalog/workspaces" -Method POST -Query @{} -Token "t").Status -eq 405) "A wrong method is 405"
Assert ((Invoke-CatalogRequest -Path "/api/catalog/items" -Method GET -Query @{ workspaceId = "x" } -Token "t").Status -eq 400) "A bad workspace ID is 400"
Assert ((Invoke-CatalogRequest -Path "/api/catalog/upstream" -Method GET -Query @{ workspaceId = $script:Ids.ws; datasetId = "" } -Token "t").Status -eq 400) "A missing dataset ID is 400"
Assert ($script:Calls.Count -eq 0) "Rejected requests never reach the service"
$checks++

# 10. Workspaces are cached for five minutes unless refresh=1.
Reset-Fake
$first = Invoke-CatalogRequest -Path "/api/catalog/workspaces" -Method GET -Query @{} -Token "t"
$second = Invoke-CatalogRequest -Path "/api/catalog/workspaces" -Method GET -Query @{} -Token "t"
Assert ($first.Status -eq 200 -and @($first.Body.workspaces).Count -eq 3 -and $first.Body.ok) "Workspaces come back"
Assert (@($script:Calls | Where-Object { $_ -like "GET */groups" }).Count -eq 1) "The second call uses the cache"
$null = Invoke-CatalogRequest -Path "/api/catalog/workspaces" -Method GET -Query @{ refresh = "1" } -Token "t"
Assert (@($script:Calls | Where-Object { $_ -like "GET */groups" }).Count -eq 2) "refresh=1 reloads"
$checks++

# 11. Items, upstream and names through the endpoint; JSON keeps lists as lists.
Reset-Fake
$itemsReply = Invoke-CatalogRequest -Path "/api/catalog/items" -Method GET -Query @{ workspaceId = $script:Ids.ws } -Token "t"
Assert ($itemsReply.Status -eq 200 -and @($itemsReply.Body.dataflows).Count -eq 2) "Items come back"
$upstreamReply = Invoke-CatalogRequest -Path "/api/catalog/upstream" -Method GET -Query @{ workspaceId = $script:Ids.ws; datasetId = $script:Ids.model } -Token "t"
Assert ($upstreamReply.Status -eq 200 -and $upstreamReply.Body.model.name -eq "Dashboard" -and @($upstreamReply.Body.dataflows).Count -eq 2) "Upstream comes back"
$namesReply = Invoke-CatalogRequest -Path "/api/catalog/names" -Method POST -Query $null -Body ([pscustomobject]@{ workspaceIds = @($script:Ids.ws); dataflows = @(); semanticModels = @([pscustomobject]@{ workspaceId = $script:Ids.ws; id = $script:Ids.model }) }) -Token "t"
Assert ($namesReply.Status -eq 200 -and @($namesReply.Body.semanticModels)[0].name -eq "Dashboard") "Names come back"
$json = $namesReply.Body | ConvertTo-Json -Depth 10 -Compress
Assert ($json -match '"workspaces":\[\{' -and $json -match '"dataflows":\[\]') "Single-item and empty lists stay JSON arrays"
$checks++

# 12. Errors: authorization is 401, anything else 502 with safe text.
Reset-Fake
$script:Fail['^/groups/[^/]+/reports$'] = "Power BI rejected authorization even after silent renewal."
Assert ((Invoke-CatalogRequest -Path "/api/catalog/items" -Method GET -Query @{ workspaceId = $script:Ids.ws } -Token "t").Status -eq 401) "An authorization error is 401"
Reset-Fake
$script:Fail["^/groups/$($script:Ids.ws)/datasets/$($script:Ids.model)$"] = "Response status code does not indicate success: 404 (Not Found). Bearer eyJabcdefgh.eyJabcdefgh.sigsigsig"
$failed = Invoke-CatalogRequest -Path "/api/catalog/upstream" -Method GET -Query @{ workspaceId = $script:Ids.ws; datasetId = $script:Ids.model } -Token "t"
Assert ($failed.Status -eq 502 -and $failed.Body.error -like "Power BI lookup failed*" -and $failed.Body.error -notmatch 'eyJabcdefgh\.') "Other failures are 502 with token-shaped text removed"
$checks++

# 13. The server loads the catalog, routes /api/catalog/ to it, and the catalog only reads.
Assert ($serverSource -match '\. \(Join-Path \$scriptDir "runtime\\refresh-catalog\.ps1"\)') "server.ps1 loads the catalog"
Assert ($serverSource -match '"\^/api/catalog/" \{[\s\S]*?Invoke-CatalogRequest') "server.ps1 routes /api/catalog/ to Invoke-CatalogRequest"
$catalogSource = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "runtime\refresh-catalog.ps1"))
Assert ($catalogSource -notmatch '-Method\s+(POST|PUT|PATCH|DELETE)') "The catalog module never writes"
Assert (@([System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot "runtime\refresh-catalog.ps1")) | Where-Object { $_ -gt 127 }).Count -eq 0) "The catalog module is ASCII-only"
$checks++

Write-Host "Catalog tests OK ($checks checks)"
