$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

$localOnlyFiles = @(
    ".token",
    ".env",
    "profiles.json",
    "rebind-profiles.json",
    "partition-refresh-profiles.json",
    "refresh-status.json",
    "refresh-worker.json",
    "rebind-status.json",
    "partition-refresh-status.json",
    "_worker.ps1",
    "_rebind-worker.ps1",
    "SECURITY_REVIEW.md"
)

$foundLocalFiles = @(
    foreach ($relativePath in $localOnlyFiles) {
        if (Test-Path -LiteralPath (Join-Path $projectRoot $relativePath)) {
            $relativePath
        }
    }
)
if (Test-Path -LiteralPath (Join-Path $projectRoot "logs")) {
    $foundLocalFiles += "logs/"
}

$sourceFiles = Get-ChildItem -LiteralPath $projectRoot -Recurse -Force -File |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }

# The text scans below skip binary files (the manual's PDF and screenshots): compressed
# bytes produce false hits for the ID and thumbprint patterns.
$binaryExtensions = @(".pdf", ".png", ".ico", ".jpg", ".jpeg", ".gif", ".zip")
$textFiles = @($sourceFiles | Where-Object { $binaryExtensions -notcontains $_.Extension.ToLowerInvariant() })

# Private notes, backups, certificates, and validation configs that name real reports.
foreach ($file in $sourceFiles) {
    $relative = $file.FullName.Substring($projectRoot.Length).TrimStart('\', '/')
    $isPrivate = ($file.Name -like "HANDOFF*.md") -or ($file.Name -like "CONVERGENCE*.md") -or
        ($file.Name -match '\.bak($|-)') -or (@(".pfx", ".cer", ".p12") -contains $file.Extension) -or
        ($relative -like "validation\reports\*.config.json" -and $file.Name -ne "example.config.json")
    if ($isPrivate) { $foundLocalFiles += $relative }
}
if ($foundLocalFiles.Count -gt 0) {
    throw "Local data must not be published: $($foundLocalFiles -join ', ')"
}

$forbiddenPatterns = [ordered]@{
    "Power Automate trigger URL" = 'https://[^/\s]+/workflows/[^?\s]+/triggers/[^?\s]+/invoke'
    "Hard-coded email webhook environment value" = '(?im)^\s*(?:\$env:)?REFRESH_EMAIL_WEBHOOK_URL\s*=\s*["''][^"'']+'
    "Local repository path" = '(?i)\b[A-Z]:\\repos\\'
    "Certificate thumbprint" = '(?<![0-9A-Fa-f])[0-9A-Fa-f]{40}(?![0-9A-Fa-f])'
}

$findings = @()
foreach ($pattern in $forbiddenPatterns.GetEnumerator()) {
    foreach ($file in $textFiles) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        if ($text -match $pattern.Value) {
            $findings += "$($pattern.Key): $($file.Name)"
        }
    }
}

# Email addresses are allowed only on reserved example domains.
$emailPattern = '(?i)\b[A-Z0-9._%+-]+@([A-Z0-9-]+(?:\.[A-Z0-9-]+)+)\b'
$exampleDomains = '(?i)^(example\.(com|org|net|invalid)|company\.com|contoso\.com)$'
$emailFiles = @(
    foreach ($file in $textFiles) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        foreach ($match in [regex]::Matches($text, $emailPattern)) {
            if ($match.Groups[1].Value -match $exampleDomains) { continue }
            $file.Name
            break
        }
    }
)
if ($emailFiles.Count -gt 0) {
    $findings += "Email address outside the example domains: $($emailFiles -join ', ')"
}

# Workspace, dataset, and dataflow IDs are private. All-zero GUIDs are deliberate
# test placeholders; $publicIds are first-party Microsoft app IDs, not credentials.
$publicIds = @(
    "1950a258-227b-4e31-a9cf-717495945fc2"  # Microsoft Azure PowerShell public client app
)
$guidPattern = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'

$idFiles = @(
    foreach ($file in $textFiles) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        foreach ($match in [regex]::Matches($text, $guidPattern)) {
            $id = $match.Value.ToLowerInvariant()
            if ($id -like "00000000-0000-0000-0000-*") { continue }
            if ($publicIds -contains $id) { continue }
            $file.Name
            break
        }
    }
)
if ($idFiles.Count -gt 0) {
    $findings += "Workspace/dataset/dataflow ID: $($idFiles -join ', ')"
}

if ($findings.Count -gt 0) {
    throw "Potential private data found: $($findings -join '; ')"
}

Write-Host "Public-release check passed: no local data, IDs, thumbprints, private email addresses, or trigger URL found." -ForegroundColor Green
