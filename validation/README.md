# Validated refresh: Power BI refresh with data validation

The validation stage around the repository's shared refresh runner
(`runtime\Invoke-RefreshRun.ps1`, the same code the Control Panel's Refresh tab and the
Claude skill `powerbi-chained-refresh` use). Sign-in goes through `runtime\powerbi-auth.ps1`
and the email through `refresh-email.ps1`, both in this repository. It works for any
report that has a config in `reports\`; `reports\example.config.json` shows the format
for a fictional model.

## Every refresh is validated

Since 2026-11-19 the runner itself validates every refresh, whether it comes from the
Control Panel, the Claude skill, a report or a profile, and always sends this folder's
email; the old plain refresh email is gone. For each semantic model in the run it takes a
snapshot before the refresh and another after it, compares them, and adds one section per
model to the email. Which checks a model gets:

- A config in `reports\` whose `workspaceName` and `semanticModelName` match the model
  (or, for a config without `semanticModelName`, whose `reportName` matches the report):
  that config's checks.
- Otherwise the universal checks in `universal-checks.json`, which need no DAX of their
  own and work for any model: rows per table (`table_rows`) and the model structure.

A check that cannot run never stops the refresh; the email says why the section is
missing. The snapshots and comparisons sit in the runner's run folder as
`validation-<n>-before.json`, `validation-<n>-after.json` and
`validation-<n>-compare.json`, next to `email.html`, and `summary.json` carries a
`Validation` field with the verdict of each model. `Invoke-ValidatedRefresh.ps1` below
does its own validation (baselines, history, the pre-check gate), so it starts the
runner with `-NoValidation`.

Rows per table counts every table that is stored in memory (Import or Dual), skipping
automatic date tables, calculation groups and tables without columns (a measures-only
table cannot be counted). A table WARNs at a 10% change and FAILs at 25%, or when it had
rows and now has none; a table that is no longer counted WARNs, and a new table passes.
The email shows the totals, the tables that changed, and how many stayed the same.

Run data lives in `%LOCALAPPDATA%\PowerBIValidation\reports`, so earlier runs remain
usable as baselines. `-SkillRoot` runs against an installed copy of the Claude skill on
purpose; the `POWERBI_REFRESH_SKILL_ROOT` variable is not read.

## What it does

1. Takes a run lock for the report and refuses to start when another run holds it or
   when the semantic model is already refreshing in the Power BI service.
2. Runs read-only DAX checks against the current semantic model (`before.json`). If any
   check cannot run, it stops here and the refresh is not started (override with
   `-ContinueOnPrecheckError`).
3. Runs the shared refresh runner as a child process: upstream dataflows, then the
   model. It is invoked without recipients, so it does not send its own email, and the
   run is found by its `summary.json` (the contract in `..\_refresh-contract.ps1`).
4. Takes a fresh token and runs the same checks again (`after.json`).
5. Compares the two snapshots and writes `compare.json` and a line per check to
   `history.csv`.
6. Writes the rendered email to the run folder and sends it, or keeps it as
   `email-preview.html` with `-PreviewEmail`.

Every run writes `validation-summary.json`, also when it stops early; a run that stops
after the lock still emails a "run did not complete" report.

## Checks in the example config (`example`)

`reports\example.config.json` describes a fictional report "Sales Dashboard" in the
workspace "Contoso TEST", with a fact table `Sales` and a `Calendar` table. Replace the
names and the DAX with your own model's.

- `Sales Amount` per month for the last 14 months, same months before and after the
  refresh (catches restatements). WARN 10%, FAIL 25%.
- Total rows of `Sales`. WARN 5%, FAIL 15%, zero is FAIL.
- Rows per month for the same 14 months. WARN 10%, FAIL 25%; a missing month or a month
  with no rows is FAIL. A month that leaves the window because a new month arrived is
  not compared.
- Latest period: PASS while it is at most 2 months old, WARN when older, FAIL when it
  moves backwards.

Checks marked `severity: info` show as INFO and never change the overall verdict; the
example has none.

## Baselines and history

By default a run compares its post-refresh snapshot with its own pre-refresh snapshot:
exactly what this refresh changed. `-BaselineRunsBack N` compares with a previous usable
run instead (`1` = the most recent). A usable run has a successful refresh, a post-check
without query errors, and no FAIL verdict. A FAIL run becomes usable after someone
accepts it by creating an empty `accepted.json` in its run folder.

### Deployments and baselines

The default before snapshot is taken immediately before the refresh, so it already
includes any deployment made earlier. Two consequences matter after a model deployment:

- The structure section compares this refresh with itself. Tables, columns, measures and
  relationships changed by the deployment are not reported; only changes made by the
  refresh appear.
- The before values are whatever the deployed model holds. An in-place definition update
  keeps the data of tables that still exist, so these values are usually real production
  figures, not zeros; new tables start empty and removed tables are gone. An empty before
  snapshot is not an error either: a month or a table without a previous value counts as
  new and passes, and a missing previous date passes.

To measure what a deployment changed, make the first refresh after it compare against a
run from before it:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-ValidatedRefresh.ps1 -Report example -Recipients you@example.com -BaselineRunsBack 1

`N` counts usable runs back from the newest, excluding the current one, and the email
names the run it used. A usable run needs a successful refresh, a post-check without
query errors and no FAIL verdict, or an `accepted.json`. A `-SkipRefresh` pre-check made
before the deployment is a useful record of that state, but it is not a usable baseline,
and there is no option yet to pass a snapshot file directly. If no earlier usable run
exists, note the deployment date and model change in the run notes: the first refresh
after a deployment can only report what the refresh itself changed.

## Requirements

Same as the Control Panel's Refresh tab: Windows PowerShell 5.1, MSAL.PS, the
service-principal certificate and its environment variables (see the repository
README), and, for live email, `REFRESH_EMAIL_WEBHOOK_URL`. The `executeQueries` endpoint additionally needs the tenant
settings "Dataset Execute Queries REST API" and "Allow service principals to use Power
BI APIs", and Build permission on the model (included in workspace Contributor and
Member).

## Usage

`-Report <name>` selects `reports\<name>.config.json`. While only one config exists it
can be left out; `-ConfigPath` points at a config anywhere.

Pre-check only, no refresh, no email. Use it to test connectivity and the queries:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-ValidatedRefresh.ps1 -Report example -SkipRefresh

Full run, real refresh, email written as a preview instead of sent:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-ValidatedRefresh.ps1 -Report example -Recipients you@example.com -PreviewEmail

Full run with a live email, detached:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-ValidatedRefresh.ps1 -Report example -Recipients you@example.com

Semantic model only, upstream dataflows left alone (exact names, one comma-separated
argument, because `powershell.exe -File` cannot take an array):

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-ValidatedRefresh.ps1 -Report example -Recipients you@example.com -ExcludeDataflow "Sales Dataflow,Dictionaries"

Exit code: 0 when the run completed and the refresh succeeded; 1 when the run stopped
early, the refresh failed, or a live email could not be sent.

## Artifacts

Run data contains real business figures, so it lives outside the code folder by
default: `%LOCALAPPDATA%\PowerBIValidation\reports\<workspace - report>\`. The root is
chosen in this order: `-ArtifactsRoot`, the `POWERBI_VALIDATION_ARTIFACTS_ROOT`
environment variable, `artifactsRoot` in the config, then that default. Environment
variables in the path are expanded; a relative path resolves against the tool folder.

- `run.lock` while a run is active
- `history.csv`, one row per check per run, with run folders relative to the report folder
- `runs\<timestamp>\validation-log.txt`, `validation-summary.json`
- `runs\<timestamp>\before.json`, `after.json`, `compare.json`, `baseline.json` when a
  previous run is used
- `runs\<timestamp>\email.html` (live) or `email-preview.html` (preview)

## Configuration

One file per report in `reports\`, named `<name>.config.json`, saved as UTF-8 without
BOM. It holds the workspace, report, recipients, artifacts root, checks, and an optional
`emailNote`: one short line printed in small grey text at the bottom of the email, in any
language (the example has a Russian summary of the PASS/WARN/FAIL limits). Edit the
note by hand when you change a threshold; it is not generated.

Removing a check from a config is safe: a baseline snapshot from an older run that still
holds it simply skips it.

`modelStructure: true` adds a "Model structure" section to the email: the number of
tables, columns (without the internal `RowNumber` columns), measures and relationships
before and after, and the names that were added or removed (up to 30 per line). It has no
result and never changes the verdict, the counts or the run's outcome; a failed structure
query is shown in that section only. The names come from the `INFO.VIEW` DAX functions,
which work through `executeQueries` with read access for any model, so no DAX is needed
in the config. The older `INFO.*` functions are refused there (`400`) because they need
admin rights. A relationship is identified by its text, for example
`'Sales'[Date] *[<-]1 'Calendar'[Date]`, so a changed cardinality or filter
direction shows as one removed and one added. Snapshots made before this option have no
structure; comparing with one shows only the current counts.

To add a report: copy `example.config.json` to `reports\<name>.config.json`,
set `workspaceName` and `reportName`, and rewrite the DAX queries for that model (the
table, date column and measure names are model-specific). Run `-Report <name>
-SkipRefresh` until the pre-check shows no errors.

Each check has:

- `kind`: `scalar`, `scalar_date`, `table`, or `table_rows` (rows per table, no query)
- `query`: DAX evaluated through `executeQueries`; `{monthsBack}` is replaced for tables
- `warnPercent` / `failPercent`: absolute percent change thresholds
- `format`: `N0`, `N2` and so on; `dateFormat` for dates
- `maxAgeMonths` (dates): age-based freshness; `mustAdvance` (dates): WARN when unchanged
- `severity`: `info` to show the check as INFO without letting it change the overall
  verdict. The example uses none.
- `showMonths` (tables): `false` keeps the month-by-month table out of the email. The
  check still runs and decides its verdict, and the months that need attention are named
  in its row of the checks table. The example shows only the Sales Amount table.

The email starts with the refresh card: header with the result mark, start, finish,
duration and the refresh table. Below it, a validation block in the same style has its
own mark and heading, one row per check, and the monthly tables that are not hidden.
For a monthly check, Before and After are totals over the months present in both
snapshots (a new month is left out and the note says so); its verdict still comes from
the individual months.

Derived checks (`derivedChecks`) read the monthly results: `comparison` is `lastYear` or
the rolling average of `monthsAveraged` months, with `warnDeviationPercent`,
`failDeviationPercent`, `minRowRatio` for the completeness guard, and `severity`. The
same-month-last-year comparison expects month keys formatted `yyyy-MM`. The example has
no derived checks.

## Tests

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ValidationLogic.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ValidationBaseline.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-UniversalChecks.ps1

All three are offline. `Test-ValidationLogic.ps1` uses the example config, and
`Test-UniversalChecks.ps1` covers the universal checks and how a config is found. The
runner's own validation stage is tested in `..\_runner-tests.ps1`.

A private copy can hold two more tests that need a real model: `Test-ValidationDryRun.ps1`
takes a real `before.json` (run `-SkipRefresh` once, or pass `-BeforePath`) and writes
email previews to a temporary folder; `Test-FailurePaths.ps1` replaces only the refresh with
`tests\fakes\fake-refresh.ps1`, while authentication and DAX queries are real and
read-only.
