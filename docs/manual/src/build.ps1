<#
.SYNOPSIS
    Builds the user manual: the HTML from gen.py, then the PDF from that HTML with headless Chrome.

.DESCRIPTION
    Writes docs\manual\PowerBI-Control-Panel-Manual-RU.html and .pdf. Needs Python 3 with
    Pillow and Google Chrome. Chrome runs with a temporary profile, so it never touches a
    running browser or its profile. Run it again after any change in this folder.
#>
param(
    [string]$Chrome = "C:\Program Files\Google\Chrome\Application\chrome.exe"
)

$ErrorActionPreference = "Stop"
$src = $PSScriptRoot
$out = Split-Path -Parent $src
$html = Join-Path $out "PowerBI-Control-Panel-Manual-RU.html"
$pdf = Join-Path $out "PowerBI-Control-Panel-Manual-RU.pdf"

python (Join-Path $src "gen.py")
if ($LASTEXITCODE -ne 0) { throw "gen.py failed" }
if (-not (Test-Path -LiteralPath $Chrome)) { throw "Chrome not found: $Chrome" }

$profileDir = Join-Path ([IO.Path]::GetTempPath()) ("manual-pdf-" + [IO.Path]::GetRandomFileName())
# Chrome prints to a temporary file first: it cannot replace a PDF that a viewer holds open
# and does not report that, so the copy below is what proves the PDF was updated.
$tempPdf = Join-Path ([IO.Path]::GetTempPath()) ("manual-" + [IO.Path]::GetRandomFileName() + ".pdf")
$chromeArgs = @(
    "--headless=new",
    "--no-pdf-header-footer",
    "--force-prefers-color-scheme=light",
    "--user-data-dir=`"$profileDir`"",
    "--print-to-pdf=`"$tempPdf`"",
    ([Uri]$html).AbsoluteUri
)
try {
    $process = Start-Process -FilePath $Chrome -ArgumentList $chromeArgs -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $tempPdf)) { throw "Chrome did not print the PDF (exit code $($process.ExitCode))" }
} finally {
    if (Test-Path -LiteralPath $profileDir) { Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue }
}
try {
    Copy-Item -LiteralPath $tempPdf -Destination $pdf -Force -ErrorAction Stop
} catch {
    throw "The PDF could not be replaced, probably because it is open in a viewer. Close it and run build.ps1 again. The new PDF is at $tempPdf"
}
Remove-Item -LiteralPath $tempPdf -Force -ErrorAction SilentlyContinue
Write-Host "PDF written: $pdf ($([Math]::Round((Get-Item -LiteralPath $pdf).Length / 1MB, 2)) MB)"
