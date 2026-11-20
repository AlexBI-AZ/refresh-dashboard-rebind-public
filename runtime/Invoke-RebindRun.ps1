# Runs one Rebind Scan or Apply in its own process. server.ps1 starts it hidden through
# powershell.exe; the logic lives in rebind-core.ps1. Exit codes: 0 finished (the status
# file says whether it passed), 1 unexpected error, 3 another Rebind operation holds the
# lock and nothing was written.
#
# Windows PowerShell 5.1. Keep this file ASCII-only.
param(
    [Parameter(Mandatory = $true)][ValidateSet("Scan", "Apply")][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OperationId,
    [Parameter(Mandatory = $true)][string]$PayloadBase64,
    [Parameter(Mandatory = $true)][string]$StatusFile,
    [Parameter(Mandatory = $true)][string]$LockFile,
    [string]$ErrorLogPath = ""
)

$ErrorActionPreference = "Stop"
. ([System.IO.Path]::Combine($PSScriptRoot, "rebind-core.ps1"))
exit (Invoke-RebindWorker -Mode $Mode -OperationId $OperationId -PayloadBase64 $PayloadBase64 -StatusFile $StatusFile -LockFile $LockFile -ErrorLogPath $ErrorLogPath)
