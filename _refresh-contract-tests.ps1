# Pins the interfaces listed in _refresh-contract.ps1 against today's producers and
# consumers: the Refresh tab (index.html), server.ps1, the refresh worker template,
# the email module, and the skill's invoke-refresh-report.ps1 (when it is installed).
# Offline: nothing here signs in or calls the service.
param(
    # Folder holding the skill's scripts. Defaults to POWERBI_REFRESH_SKILL_ROOT\scripts,
    # then the personal skill folder. The summary checks are skipped when it is absent.
    [string]$SkillScriptsRoot
)

$ErrorActionPreference = "Stop"

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-ParsedScript {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) "$(Split-Path -Leaf $Path) must parse"
    return $ast
}

function Get-HashtableKeySets {
    # Key lists of every hashtable literal in the script that has all the marker keys.
    param($Ast, [string[]]$MarkerKeys)
    $sets = @()
    foreach ($table in $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $true)) {
        $keys = @($table.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text.Trim('"', "'") })
        $missing = @($MarkerKeys | Where-Object { $keys -notcontains $_ })
        if ($missing.Count -eq 0) { $sets += ,$keys }
    }
    return ,$sets
}

function Get-AssignedMembers {
    # Names X in "$<variable>.X = ..." and "$<variable>.X += ...".
    param($Ast, [string]$VariableName)
    $names = @()
    foreach ($assignment in $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        $left = $assignment.Left
        if ($left -is [System.Management.Automation.Language.MemberExpressionAst] -and
            $left.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $left.Expression.VariablePath.UserPath -eq $VariableName) {
            $names += $left.Member.Extent.Text
        }
    }
    return @($names | Sort-Object -Unique)
}

function Assert-SameSet {
    param([string[]]$Actual, [string[]]$Expected, [string]$What)
    $extra = @($Actual | Where-Object { $Expected -notcontains $_ })
    $missing = @($Expected | Where-Object { $Actual -notcontains $_ })
    Assert ($extra.Count -eq 0 -and $missing.Count -eq 0) "$What differs from the contract. Extra: $($extra -join ', '). Missing: $($missing -join ', ')."
}

function Assert-Subset {
    param([string[]]$Actual, [string[]]$Allowed, [string]$What)
    $extra = @($Actual | Where-Object { $Allowed -notcontains $_ } | Sort-Object -Unique)
    Assert ($extra.Count -eq 0) "$What uses fields outside the contract: $($extra -join ', ')."
}

. (Join-Path $PSScriptRoot "_refresh-contract.ps1")
$checks = 0

# --- refresh-status.json -----------------------------------------------------------
# The status file is written by the shared runner (runtime\refresh-engine.ps1), which the
# Refresh tab starts; the old worker template is gone.
$templateAst = Get-ParsedScript (Join-Path $PSScriptRoot "runtime\refresh-engine.ps1")
$initialSets = Get-HashtableKeySets $templateAst @("logs", "dataflowStatus")
Assert ($initialSets.Count -eq 1) "The runner should write exactly one initial status object"
Assert-SameSet $initialSets[0] $RefreshStatusFields "The runner's initial status object"; $checks++

$workerAssigned = Get-AssignedMembers $templateAst "state"
Assert-Subset $workerAssigned $RefreshStatusFields "The runner's status updates"; $checks++
$missingFinal = @($RefreshStatusFinalFields | Where-Object { $workerAssigned -notcontains $_ })
Assert ($missingFinal.Count -eq 0) "The runner never sets final status fields: $($missingFinal -join ', ')"; $checks++

$serverAst = Get-ParsedScript (Join-Path $PSScriptRoot "server.ps1")
$serverSets = Get-HashtableKeySets $serverAst @("running", "dataflowStatus")
Assert ($serverSets.Count -ge 3) "server.ps1 should write the start, failed-start and empty status objects"
foreach ($set in $serverSets) { Assert-Subset $set $RefreshStatusFields "A server.ps1 status object" }
$checks++
Assert (@($serverSets | Where-Object { $_.Count -eq $RefreshStatusFields.Count }).Count -ge 1) "server.ps1 should write a complete status object when a refresh starts"; $checks++

$html = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "index.html"))
$poll = [regex]::Match($html, 'async function pollStatus\(\)[\s\S]*?\nfunction stopPolling')
Assert $poll.Success "index.html should contain pollStatus"
$uiStateFields = @([regex]::Matches($poll.Value, 'state\.(\w+)') | ForEach-Object { $_.Groups[1].Value })
Assert ($uiStateFields.Count -gt 0) "pollStatus should read the status object"
Assert-Subset $uiStateFields ($RefreshStatusFields + @("length")) "The Refresh tab's pollStatus"; $checks++
$uiLogFields = @([regex]::Matches($poll.Value, 'entry\.(\w+)') | ForEach-Object { $_.Groups[1].Value })
Assert-Subset $uiLogFields ($RefreshLogEntryFields + @("text")) "The Refresh tab's log rendering"; $checks++
$render = [regex]::Match($html, 'function renderSemanticModelStatus\(details\)[\s\S]*?\n\}')
Assert $render.Success "index.html should contain renderSemanticModelStatus"
$uiModelFields = @([regex]::Matches($render.Value, 'detail\.(\w+)') | ForEach-Object { $_.Groups[1].Value })
Assert-SameSet @($uiModelFields | Sort-Object -Unique) $RefreshModelDetailUiFields "The Refresh tab's semantic model rows"; $checks++

$modelDetailSets = Get-HashtableKeySets $templateAst @("requestId", "completedAt")
Assert ($modelDetailSets.Count -ge 1) "The runner should declare semantic model details"
$missingModelFields = @($RefreshModelDetailUiFields | Where-Object { $modelDetailSets[0] -notcontains $_ })
Assert ($missingModelFields.Count -eq 0) "Runner model details lack UI fields: $($missingModelFields -join ', ')"; $checks++

$doneMatch = [regex]::Match($poll.Value, "state\.result === '(\w+)' \|\| \(state\.dataflowStatus === '(\w+)' && state\.datasetStatus === '(\w+)'\)")
Assert $doneMatch.Success "pollStatus should decide success from result, dataflowStatus and datasetStatus"
Assert ($RefreshStatusResults -contains $doneMatch.Groups[1].Value) "The UI's success result should be in the contract"
Assert ($RefreshStatusDataflowFinal -contains $doneMatch.Groups[2].Value) "The UI's dataflow success value should be in the contract"
Assert ($RefreshStatusModelFinal -contains $doneMatch.Groups[3].Value) "The UI's model success value should be in the contract"; $checks++

# --- the email ------------------------------------------------------------------------------
# Every refresh sends one format, New-ValidationEmailContent in validation\validation.ps1.
# It reads the refresh items in the summary.json item shape.
. (Join-Path $PSScriptRoot "validation\validation.ps1")
$summaryItems = @(
    foreach ($status in @("Succeeded", "Failed", "Skipped", "Unknown")) {
        $item = [ordered]@{}
        foreach ($field in $RefreshSummaryItemFields) { $item[$field] = "" }
        $item.name = "Item $status"; $item.workspaceName = "Workspace"; $item.status = $status
        [pscustomobject]$item
    }
)
$email = New-ValidationEmailContent -RefreshSummary ([pscustomobject]@{ Dataflows = $summaryItems; SemanticModels = @() }) -RunFolder "C:\run" -StartedAt (Get-Date).AddMinutes(-5) -EndedAt (Get-Date) -Title "Report"
Assert $email.RefreshFailed "Any status other than success should mark the email as an error outcome"
Assert ($email.Subject -match "refresh failed") "The subject should say the refresh failed"
foreach ($status in @("Succeeded", "Failed", "Skipped", "Unknown")) {
    Assert ($email.HtmlBody -match ">$status</td>") "The email should show the status '$status'"
}
$unknownOnly = New-ValidationEmailContent -RefreshSummary ([pscustomobject]@{ Dataflows = @($summaryItems[3]); SemanticModels = @() }) -RunFolder "C:\run" -StartedAt (Get-Date).AddMinutes(-1) -EndedAt (Get-Date) -Title "Report"
Assert $unknownOnly.RefreshFailed "An Unknown item alone should still read as a failed refresh"; $checks++
$refreshEmailSource = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "refresh-email.ps1"))
Assert ($refreshEmailSource -notmatch 'function Get-RefreshEmailContent') "The plain refresh email builder must stay gone"
$engineText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "runtime\refresh-engine.ps1"))
Assert ($engineText -match 'New-ValidationEmailContent -Sections') "The runner should build the validated email"; $checks++

# --- summary.json, first log line and plan: the runner ------------------------------------
# Since alex-custom-skills 1.7.0 the skill hands report refreshes to this runner, so the
# runner is the producer the validated refresh wrapper reads.
function Assert-OrderedKeys {
    param([string[]]$Actual, [string[]]$Expected, [string]$What)
    Assert (($Actual -join ",") -eq ($Expected -join ",")) "$What should list $($Expected -join ', ') in that order, not $($Actual -join ', ')."
}

$enginePath = Join-Path $PSScriptRoot "runtime\refresh-engine.ps1"
$engineAst = Get-ParsedScript $enginePath
$engineSource = [System.IO.File]::ReadAllText($enginePath)
$itemSelect = "Select-Object " + ($RefreshSummaryItemFields -join ", ")
$engineSummarySets = Get-HashtableKeySets $engineAst @("Workspace", "Result", "Artifacts")
Assert ($engineSummarySets.Count -eq 1) "The runner should write exactly one summary object"
Assert-SameSet $engineSummarySets[0] $RefreshSummaryFields "The runner's summary.json"; $checks++
# The summary's two lists, and the same two for the email's refresh table.
Assert (([regex]::Matches($engineSource, [regex]::Escape($itemSelect))).Count -ge 2) "The runner's summary items should carry $($RefreshSummaryItemFields -join ', ')"; $checks++
$engineFirstLine = $RefreshLogFirstLinePattern -f '$($resolved.Report)', '$($resolved.Workspace)'
Assert ($engineSource.Contains('Write-RefreshLog "' + $engineFirstLine + '"')) "The runner's first log line for a report should match the contract"; $checks++
$enginePlanSets = Get-HashtableKeySets $engineAst @("SemanticModel", "UpstreamDataflows", "Email")
Assert ($enginePlanSets.Count -eq 1) "The runner should print exactly one report plan"
Assert-OrderedKeys $enginePlanSets[0] $RefreshReportPlanFields "The runner's report plan"; $checks++

# --- the skill: either its built-in engine keeps the contract, or it delegates -----------
if ([string]::IsNullOrWhiteSpace($SkillScriptsRoot)) {
    $skillRoot = [Environment]::GetEnvironmentVariable("POWERBI_REFRESH_SKILL_ROOT", "User")
    if ([string]::IsNullOrWhiteSpace($skillRoot)) { $skillRoot = Join-Path $env:USERPROFILE ".claude\skills\powerbi-chained-refresh" }
    $SkillScriptsRoot = Join-Path $skillRoot "scripts"
}
$skillRunner = Join-Path $SkillScriptsRoot "invoke-refresh-report.ps1"
if (Test-Path -LiteralPath $skillRunner) {
    $skillAst = Get-ParsedScript $skillRunner
    $skillSource = [System.IO.File]::ReadAllText($skillRunner)
    $delegates = $skillSource.Contains('runtime\Invoke-RefreshRun.ps1')
    $summarySets = Get-HashtableKeySets $skillAst @("Workspace", "Result", "Artifacts")
    if ($summarySets.Count -eq 0) {
        # A skill without its own engine must hand every run to the runner checked above.
        Assert $delegates "The skill neither writes a summary nor delegates to runtime\Invoke-RefreshRun.ps1"; $checks++
    } else {
        Assert ($summarySets.Count -eq 1) "The skill should write exactly one summary object"
        Assert-SameSet $summarySets[0] $RefreshSummaryFieldsWithoutValidation "The skill's built-in summary.json"; $checks++
        Assert (([regex]::Matches($skillSource, [regex]::Escape($itemSelect))).Count -eq 2) "The skill's summary items should carry $($RefreshSummaryItemFields -join ', ')"; $checks++
        $firstLine = $RefreshLogFirstLinePattern -f '$($report.name)', '$($workspace.name)'
        Assert ($skillSource.Contains('Write-RunLog "' + $firstLine + '"')) "The skill's first log line should match the contract"; $checks++
        $skillPlanSets = Get-HashtableKeySets $skillAst @("SemanticModel", "UpstreamDataflows", "Email")
        Assert ($skillPlanSets.Count -eq 1) "The skill should print exactly one report plan"
        Assert-OrderedKeys $skillPlanSets[0] $RefreshReportPlanFields "The skill's report plan"; $checks++
    }
    $skillMode = if ($delegates) { "delegates to the runner" } else { "built-in engine only" }
    Write-Host "Skill checked at $SkillScriptsRoot ($skillMode)"
} else {
    Write-Host "SKIPPED: skill checks (skill scripts not found)" -ForegroundColor Yellow
}

# --- validated refresh (validation\, convergence phase 6) ----------------------------------
# The validation stage runs the shared runner as its refresh and finds the run by the
# summary.json and first log line checked above. Its arguments must bind to the runner.
$validatedPath = Join-Path $PSScriptRoot "validation\Invoke-ValidatedRefresh.ps1"
$validatedSource = [System.IO.File]::ReadAllText($validatedPath)
[void](Get-ParsedScript $validatedPath)
Assert ($validatedSource -match 'Join-Path \$repoRoot "runtime\\Invoke-RefreshRun\.ps1"') "The validated refresh must default to the shared runner"
Assert ($validatedSource -match 'Join-Path \$repoRoot "runtime\\powerbi-auth\.ps1"') "The validated refresh must sign in through the runtime's auth module"
Assert ($validatedSource -notmatch 'GetEnvironmentVariable\("POWERBI_REFRESH_SKILL_ROOT"|Get-ValidationConfigValue "POWERBI_REFRESH_SKILL_ROOT"') "A stale personal skill copy must not be picked up through POWERBI_REFRESH_SKILL_ROOT"
$runnerParams = @((Get-ParsedScript (Join-Path $PSScriptRoot "runtime\Invoke-RefreshRun.ps1")).ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
$childBlock = [regex]::Match($validatedSource, '\$childArguments = @\(([\s\S]*?)\)\r?\n')
Assert $childBlock.Success "The validated refresh should build its runner arguments in one place"
$passed = @([regex]::Matches($childBlock.Groups[1].Value + " " + [regex]::Match($validatedSource, '\$childArguments \+= @\(([^)]*)\)').Groups[1].Value, '"-(\w+)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notin @("NoProfile", "ExecutionPolicy", "File") })
Assert ($passed -contains "ExcludeDataflow" -and $passed -contains "WorkspaceName") "The argument scan should see the report and exclusion arguments"
$unknownArgs = @($passed | Where-Object { $runnerParams -notcontains $_ })
Assert ($unknownArgs.Count -eq 0) "The validated refresh passes arguments the runner does not have: $($unknownArgs -join ', ')"
$checks++

Write-Host "Refresh interface contract tests OK ($checks checks)"
