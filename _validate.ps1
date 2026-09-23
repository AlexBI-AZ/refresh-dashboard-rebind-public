$src = Get-Content (Join-Path $PSScriptRoot "server.ps1") -Raw
$errors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$tokens, [ref]$errors)
if ($errors.Count -eq 0) {
    Write-Host "Parse OK - no syntax errors"
} else {
    Write-Host "PARSE ERRORS ($($errors.Count)):"
    foreach ($e in $errors) { Write-Host "  $($e.Message)" }
}
