# Offline tests for setup.ps1. Nothing here changes the real user: user variables, the
# certificate store, the module install, shortcuts and the panel start are all replaced by
# fakes, and every file the setup writes goes to a temporary sandbox folder.
# Run with Windows PowerShell 5.1: powershell -ExecutionPolicy Bypass -File .\_setup-tests.ps1

$ErrorActionPreference = "Stop"

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$repo = $PSScriptRoot
$setupPath = Join-Path $repo "setup.ps1"
$batPath = Join-Path $repo "setup.bat"
$checks = 0

# --- files: encoding, syntax, and what the script must never do ---------------------
foreach ($path in @($setupPath, $batPath)) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    Assert (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) "$path must not start with a BOM"
    Assert (-not ($bytes | Where-Object { $_ -gt 127 })) "$path must be ASCII-only (Windows PowerShell 5.1 reads it as ANSI)"
}
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($setupPath, [ref]$null, [ref]$parseErrors) | Out-Null
Assert ($parseErrors.Count -eq 0) "setup.ps1 must parse: $($parseErrors | Select-Object -First 1)"
$setupText = [System.IO.File]::ReadAllText($setupPath)
Assert ($setupText -notmatch '(?i)New-SelfSignedCertificate|(Export|Import)-(Pfx)?Certificate|CertificateRequest|X509ContentType|OpenFlags\]::(ReadWrite|MaxAllowed)') "setup.ps1 must never create, import or export a certificate"
Assert ($setupText -notmatch '(?i)\b(Set-Content|Add-Content|Out-File)\b') "setup.ps1 must not write text files (the flow URL lives only in a user variable)"
Assert ($setupText -notmatch '(?i)Set-PSRepository|InstallationPolicy') "setup.ps1 must not change the PSGallery trust setting"
Assert ($setupText -notmatch '(?i)Machine"\)') "setup.ps1 must not write machine-wide variables"
$batText = [System.IO.File]::ReadAllText($batPath)
Assert ($batText -match 'powershell\.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\.ps1" %\*') "setup.bat must start setup.ps1 in Windows PowerShell and pass arguments on"
Assert ($batText -match "`r`n") "setup.bat must use CRLF line endings"
$checks++

# --- load the functions without running the setup -----------------------------------
. $setupPath
Assert ($script:SetupChanges.Count -eq 0) "Dot-sourcing setup.ps1 must not run it"
$checks++

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("setup-tests-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $sandbox | Out-Null
$appRoot = Join-Path $sandbox "app folder"
New-Item -ItemType Directory -Path (Join-Path $appRoot "runtime") -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repo "favicon.png") -Destination $appRoot
Copy-Item -LiteralPath (Join-Path $repo "launch-app.bat") -Destination $appRoot
Copy-Item -LiteralPath (Join-Path $repo "runtime\powerbi-auth.ps1") -Destination (Join-Path $appRoot "runtime")
$script:SetupRoot = $appRoot

# Fakes. Each records its calls; a test can make any of them throw.
$script:Calls = New-Object System.Collections.Generic.List[string]
$script:FakeVars = @{}
$script:FakeStore = New-Object System.Collections.Generic.List[object]
$script:FakeMsal = $true
$script:Answers = New-Object System.Collections.Generic.Queue[string]
$script:SecretAnswers = New-Object System.Collections.Generic.Queue[string]
$script:ForbidChanges = $false

function Register-Call([string]$Name) {
    if ($script:ForbidChanges) { throw "Dry run called $Name" }
    $script:Calls.Add($Name)
}

function Get-PowerBiConfigValue {
    param([string]$Name)
    $value = $script:FakeVars[$Name]
    return [pscustomobject]@{ Name = $Name; Value = $value; Scope = $(if ($value) { "User" } else { "not set" }); StaleProcessCopy = $false }
}
function Set-SetupUserVariable([string]$Name, [string]$Value) { Register-Call "var:$Name"; $script:FakeVars[$Name] = $Value }
function Test-SetupMsalModule { return $script:FakeMsal }
function Install-SetupMsalModule { Register-Call "install-msal"; $script:FakeMsal = $true }
function Repair-SetupModulePath { }
function Test-SetupPanelRunning { return $false }
function Start-SetupPanel([string]$Root) { Register-Call "start-panel" }
function Read-SetupLine([string]$Prompt) { if ($script:Answers.Count -eq 0) { throw "Unexpected question: $Prompt" }; return $script:Answers.Dequeue() }
function Read-SetupSecret([string]$Prompt) { if ($script:SecretAnswers.Count -eq 0) { throw "Unexpected secret question: $Prompt" }; return $script:SecretAnswers.Dequeue() }
function Get-SetupShortcutPaths { return @((Join-Path $sandbox "Desktop\Power BI Control Panel.lnk"), (Join-Path $sandbox "Programs\Power BI Control Panel.lnk")) }
function Get-SetupIconPath { return (Join-Path $sandbox "AppData\app.ico") }

function New-TestCertificate([string]$Subject, [switch]$Expired) {
    # In memory only (never in a certificate store); stands in for one set up earlier.
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $request = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest($Subject, $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    if ($Expired) { return $request.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-30), [DateTimeOffset]::Now.AddDays(-1)) }
    return $request.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-1), [DateTimeOffset]::Now.AddDays(730))
}
function Get-PowerBiServicePrincipalCertificate([string]$Thumbprint) {
    $found = $script:FakeStore | Where-Object { $_.Thumbprint -eq $Thumbprint } | Select-Object -First 1
    if (-not $found) { throw "No certificate with thumbprint $Thumbprint exists." }
    return $found
}
$realShortcut = ${function:New-SetupShortcut}
function New-SetupShortcut { param([string]$Path, [string]$Target, [string]$WorkingDirectory, [string]$IconPath) Register-Call "shortcut"; & $realShortcut -Path $Path -Target $Target -WorkingDirectory $WorkingDirectory -IconPath $IconPath }
$realIcon = ${function:Write-SetupIcon}
function Write-SetupIcon([string]$PngPath, [string]$IcoPath) { Register-Call "icon"; & $realIcon $PngPath $IcoPath }
$realUnblock = ${function:Unblock-SetupFiles}
function Unblock-SetupFiles([object[]]$Files) { Register-Call "unblock"; & $realUnblock $Files }

function Reset-Fakes {
    $script:Calls.Clear()
    $script:SetupChanges.Clear()
    $script:SetupSignInChanged = $false
    $script:Answers.Clear()
    $script:SecretAnswers.Clear()
    $script:ForbidChanges = $false
    $script:SetupDryRun = $false
}

function Invoke-TestSetup {
    # Runs the setup and returns its readiness result plus everything it printed.
    param([hashtable]$Arguments)
    $output = @(Invoke-Setup @Arguments 6>&1)
    $isReadiness = { param($item) $null -ne $item -and $null -ne $item.PSObject.Properties["Ready"] -and $null -ne $item.PSObject.Properties["Items"] }
    $readiness = $output | Where-Object { & $isReadiness $_ } | Select-Object -Last 1
    $text = ($output | Where-Object { -not (& $isReadiness $_) } | ForEach-Object { [string]$_ }) -join "`n"
    return [pscustomobject]@{ Readiness = $readiness; Text = $text }
}

function Get-ReadinessItem($Run, [string]$Name) { return ($Run.Readiness.Items | Where-Object { $_.Name -eq $Name } | Select-Object -First 1) }

$tenant = "00000000-0000-0000-0000-00000000000a"
$client = "00000000-0000-0000-0000-00000000000b"
$flowUrl = "https://flow.example.invalid/workflows/0000/run?sig=TEST-SECRET-VALUE"

try {
    # --- the icon is a valid .ico that Windows can load ----------------------------------
    $iconBytes = Get-SetupIconBytes (Join-Path $appRoot "favicon.png")
    Assert ($iconBytes[0] -eq 0 -and $iconBytes[2] -eq 1 -and $iconBytes[4] -eq 1) "ICO header: type 1, one image"
    Assert ($iconBytes[6] -eq 32 -and $iconBytes[7] -eq 32) "ICO entry carries the PNG's 32 x 32 size"
    Add-Type -AssemblyName System.Drawing
    $probeIcon = Join-Path $sandbox "probe.ico"
    [System.IO.File]::WriteAllBytes($probeIcon, $iconBytes)
    $loaded = New-Object System.Drawing.Icon($probeIcon)
    Assert ($loaded.Width -eq 32) "System.Drawing must load the icon"
    $loaded.Dispose()
    $checks++

    # --- dry run: reports every change and makes none ------------------------------------
    Reset-Fakes
    $script:FakeMsal = $false
    $blockedFile = Join-Path $appRoot "launch-app.bat"
    Set-Content -LiteralPath $blockedFile -Stream "Zone.Identifier" -Value "[ZoneTransfer]`r`nZoneId=3"
    $script:SetupDryRun = $true
    $script:ForbidChanges = $true
    $run = Invoke-TestSetup @{ SignIn = "DeviceCode"; SkipWebhook = $true }
    Assert ($script:Calls.Count -eq 0) "A dry run must not change anything (calls: $($script:Calls -join ', '))"
    Assert (@($script:SetupChanges | Where-Object { $_ -like "would: unblock 1 file*" }).Count -eq 1) "Dry run reports the unblock"
    Assert (@($script:SetupChanges | Where-Object { $_ -eq "would: install MSAL.PS for the current user" }).Count -eq 1) "Dry run reports the module install"
    Assert (@($script:SetupChanges | Where-Object { $_ -like "would: create the shortcut*" }).Count -eq 2) "Dry run reports both shortcuts"
    Assert ([bool](Get-Item -LiteralPath $blockedFile -Stream "Zone.Identifier" -ErrorAction SilentlyContinue)) "Dry run leaves the file blocked"
    Assert (-not (Test-Path (Join-Path $sandbox "Desktop"))) "Dry run writes no shortcut"
    Assert ($run.Text -match "Dry run finished") "Dry run says it finished"
    Assert (-not $run.Readiness.Ready) "Readiness after the dry run is still Not ready (module missing, file blocked)"
    $checks++

    # --- device code, first run -----------------------------------------------------------
    Reset-Fakes
    $run = Invoke-TestSetup @{ SignIn = "DeviceCode"; SkipWebhook = $true }
    Assert ($script:FakeVars.Count -eq 0) "Device code must not set any variable"
    Assert (@($script:Calls | Where-Object { $_ -eq "install-msal" }).Count -eq 1) "MSAL.PS is installed once"
    Assert (@($script:Calls | Where-Object { $_ -eq "unblock" }).Count -eq 1) "Blocked files are unblocked"
    Assert (-not (Get-Item -LiteralPath $blockedFile -Stream "Zone.Identifier" -ErrorAction SilentlyContinue)) "The Zone.Identifier stream is gone"
    foreach ($link in (Get-SetupShortcutPaths)) {
        Assert (Test-SetupShortcut -Path $link -Target (Join-Path $appRoot "launch-app.bat") -IconPath (Get-SetupIconPath)) "Shortcut $link points at launch-app.bat with the icon"
    }
    $shell = New-Object -ComObject WScript.Shell
    Assert ($shell.CreateShortcut((Get-SetupShortcutPaths)[0]).WorkingDirectory -eq $appRoot) "Shortcut starts in the app folder (path with a space)"
    Assert (@($script:Calls | Where-Object { $_ -eq "start-panel" }).Count -eq 1) "The panel is opened at the end"
    Assert ($run.Readiness.Ready) "Ready after setup: $(($run.Readiness.Items | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ')"
    Assert ((Get-ReadinessItem $run "Sign-in").Detail -match "device code") "Readiness names device code"
    Assert ((Get-ReadinessItem $run "Email").Status -eq "INFO") "No flow URL is information, not a failure"
    $checks++

    # --- device code, second run changes nothing -----------------------------------------
    Reset-Fakes
    $run = Invoke-TestSetup @{ SignIn = "DeviceCode"; SkipWebhook = $true; NoLaunch = $true }
    Assert ($script:SetupChanges.Count -eq 0) "A second run must change nothing (changes: $($script:SetupChanges -join '; '))"
    Assert ($script:Calls.Count -eq 0) "A second run with -NoLaunch makes no calls"
    Assert ($run.Readiness.Ready) "Still ready"
    $checks++

    # --- no certificate on the PC: no question, device code, nothing set ------------------
    Reset-Fakes
    $run = Invoke-TestSetup @{ SkipWebhook = $true; NoLaunch = $true }
    Assert ($script:FakeVars.Count -eq 0 -and $script:Calls.Count -eq 0) "Without a certificate setup asks nothing and sets nothing"
    Assert ($run.Text -match "Sign-in: device code") "Device code is used"
    Assert ($run.Text -notmatch "Use the certificate") "No certificate is offered"
    $run = Invoke-TestSetup @{ SignIn = "Certificate"; SkipWebhook = $true; NoLaunch = $true }
    Assert ($script:FakeVars.Count -eq 0 -and $script:Calls.Count -eq 0) "-SignIn Certificate without a certificate creates and sets nothing"
    Assert ($run.Text -match "does not create certificates") "It says that setup does not create certificates"
    $checks++

    # --- a working certificate is suggested; Enter keeps it and changes nothing ------------
    Reset-Fakes
    $certificate = New-TestCertificate "CN=Existing test certificate"
    $script:FakeStore.Add($certificate)
    $script:FakeVars["POWERBI_REFRESH_TENANT_ID"] = $tenant
    $script:FakeVars["POWERBI_REFRESH_CLIENT_ID"] = $client
    $script:FakeVars["POWERBI_REFRESH_CERT_THUMBPRINT"] = $certificate.Thumbprint
    $script:Answers.Enqueue("")
    $run = Invoke-TestSetup @{ SkipWebhook = $true; NoLaunch = $true }
    Assert ($run.Text -match "already has a working certificate") "The detected certificate is suggested"
    Assert ($script:Calls.Count -eq 0) "Keeping the certificate changes nothing (calls: $($script:Calls -join ', '))"
    Assert ($run.Text -match "Sign-in: certificate") "The certificate is used"
    Assert ((Get-ReadinessItem $run "Sign-in").Detail -match "certificate") "Readiness reports the certificate"
    $checks++

    # --- answering no switches to device code; yes switches back ---------------------------
    Reset-Fakes
    $script:Answers.Enqueue("n")
    $run = Invoke-TestSetup @{ SkipWebhook = $true; NoLaunch = $true }
    Assert ($script:FakeVars["POWERBI_REFRESH_AUTH_MODE"] -eq "delegated") "No sets POWERBI_REFRESH_AUTH_MODE to delegated"
    Assert ((@($script:Calls) -join ",") -eq "var:POWERBI_REFRESH_AUTH_MODE") "Only that variable is written"
    Assert ($script:FakeVars["POWERBI_REFRESH_CERT_THUMBPRINT"] -eq $certificate.Thumbprint) "The certificate settings are left in place"
    Assert ($script:SetupSignInChanged) "The sign-in change is noticed (for the restart note)"
    Assert ((Get-ReadinessItem $run "Sign-in").Detail -match "device code") "Readiness reports device code"
    Reset-Fakes
    $script:Answers.Enqueue("n")
    $run = Invoke-TestSetup @{ SkipWebhook = $true; NoLaunch = $true }
    Assert ($script:Calls.Count -eq 0) "Saying no again changes nothing"
    Reset-Fakes
    $script:Answers.Enqueue("y")
    $run = Invoke-TestSetup @{ SkipWebhook = $true; NoLaunch = $true }
    Assert ($script:FakeVars["POWERBI_REFRESH_AUTH_MODE"] -eq "service-principal") "Yes undoes an earlier no"
    Assert ((Get-ReadinessItem $run "Sign-in").Detail -match "certificate") "Readiness reports the certificate again"
    Reset-Fakes
    $script:SetupDryRun = $true
    $script:ForbidChanges = $true
    $script:Answers.Enqueue("n")
    $run = Invoke-TestSetup @{ SkipWebhook = $true; NoLaunch = $true }
    Assert (@($script:SetupChanges | Where-Object { $_ -eq "would: set the user variable POWERBI_REFRESH_AUTH_MODE to delegated" }).Count -eq 1) "A dry run reports the switch"
    Assert ($script:FakeVars["POWERBI_REFRESH_AUTH_MODE"] -eq "service-principal") "A dry run does not switch"
    $checks++

    # --- certificate settings without a usable certificate: device code is enforced --------
    foreach ($case in @("missing", "expired")) {
        Reset-Fakes
        $script:FakeVars.Remove("POWERBI_REFRESH_AUTH_MODE")
        $script:FakeStore.Clear()
        if ($case -eq "expired") {
            $old = New-TestCertificate "CN=Expired test certificate" -Expired
            $script:FakeStore.Add($old)
            $script:FakeVars["POWERBI_REFRESH_CERT_THUMBPRINT"] = $old.Thumbprint
        }
        $run = Invoke-TestSetup @{ SkipWebhook = $true; NoLaunch = $true }
        Assert ($run.Text -notmatch "Use the certificate") "A $case certificate is not offered"
        Assert ($run.Text -match "cannot be used") "The $case certificate is explained"
        Assert ($script:FakeVars["POWERBI_REFRESH_AUTH_MODE"] -eq "delegated") "With a $case certificate, device code is set"
        Assert ($run.Readiness.Ready -and (Get-ReadinessItem $run "Sign-in").Detail -match "device code") "Ready with device code ($case certificate)"
    }
    $checks++

    # --- the readiness check alone reports a broken certificate, with the reason ----------
    Reset-Fakes
    $script:FakeVars.Remove("POWERBI_REFRESH_AUTH_MODE")
    $script:FakeStore.Clear()
    $run = Invoke-TestSetup @{ CheckOnly = $true }
    Assert (-not $run.Readiness.Ready) "Missing certificate is Not ready"
    Assert ((Get-ReadinessItem $run "Sign-in").Detail -match "No certificate") "The reason names the missing certificate"
    Assert ($run.Text -match "Not ready:") "The check prints Not ready with reasons"
    Assert ($script:Calls.Count -eq 0) "The check changes nothing"
    $checks++

    # --- broken settings are reported, not fixed ------------------------------------------
    Reset-Fakes
    $script:FakeVars.Clear()
    $script:FakeVars["POWERBI_REFRESH_AUTH_MODE"] = "service-principal"
    $run = Invoke-TestSetup @{ CheckOnly = $true }
    Assert ((Get-ReadinessItem $run "Sign-in").Detail -match "missing: POWERBI_REFRESH_TENANT_ID") "Missing certificate variables are named"
    $script:FakeVars["POWERBI_REFRESH_AUTH_MODE"] = "something-else"
    $run = Invoke-TestSetup @{ CheckOnly = $true }
    Assert ((Get-ReadinessItem $run "Sign-in").Status -eq "FAIL") "An invalid mode is a failure"
    $script:FakeVars.Clear()
    $script:FakeMsal = $false
    $run = Invoke-TestSetup @{ CheckOnly = $true }
    Assert (-not $run.Readiness.Ready -and (Get-ReadinessItem $run "MSAL.PS").Status -eq "FAIL") "A missing module is Not ready"
    Assert ($script:Calls.Count -eq 0) "The readiness check changes nothing"
    $script:FakeMsal = $true
    $checks++

    # --- flow URL: saved only as a user variable, never printed or written to a file ------
    Reset-Fakes
    $script:SecretAnswers.Enqueue($flowUrl)
    $run = Invoke-TestSetup @{ SignIn = "DeviceCode"; NoLaunch = $true }
    Assert ($script:FakeVars["REFRESH_EMAIL_WEBHOOK_URL"] -eq $flowUrl) "The flow URL is saved as the user variable"
    Assert ((@($script:Calls | Where-Object { $_ -like "var:*" }) -join ",") -eq "var:REFRESH_EMAIL_WEBHOOK_URL") "Only that one variable is written"
    Assert ($run.Text -notmatch "TEST-SECRET-VALUE") "The flow URL is never printed"
    $leaks = @(Get-ChildItem -LiteralPath $sandbox -Recurse -File | Where-Object { [System.IO.File]::ReadAllText($_.FullName) -match "TEST-SECRET-VALUE" })
    Assert ($leaks.Count -eq 0) "The flow URL is in no file: $($leaks.FullName -join ', ')"
    Assert ((Get-ReadinessItem $run "Email").Status -eq "OK") "Readiness sees the flow URL"

    Reset-Fakes
    $script:SecretAnswers.Enqueue("")
    $run = Invoke-TestSetup @{ SignIn = "DeviceCode"; NoLaunch = $true }
    Assert ($script:Calls.Count -eq 0 -and $script:FakeVars["REFRESH_EMAIL_WEBHOOK_URL"] -eq $flowUrl) "Enter keeps the saved URL"
    Assert ($run.Text -match "Kept the saved flow URL") "Keeping it is said"

    Reset-Fakes
    $script:SecretAnswers.Enqueue("http://not-https.example.invalid/workflows/x")
    $run = Invoke-TestSetup @{ SignIn = "DeviceCode"; NoLaunch = $true }
    Assert ($script:Calls.Count -eq 0 -and $script:FakeVars["REFRESH_EMAIL_WEBHOOK_URL"] -eq $flowUrl) "A non-https URL is not saved"
    Assert ($run.Text -match "Nothing was saved") "The rejection is said"

    Reset-Fakes
    $script:FakeVars.Remove("REFRESH_EMAIL_WEBHOOK_URL")
    $script:SecretAnswers.Enqueue("")
    $run = Invoke-TestSetup @{ SignIn = "DeviceCode"; NoLaunch = $true }
    Assert ($script:Calls.Count -eq 0 -and -not $script:FakeVars["REFRESH_EMAIL_WEBHOOK_URL"]) "Enter skips when nothing is saved"
    $checks++

    # --- a Windows PowerShell version check that refuses PowerShell 7 ---------------------
    Assert (Test-SetupWindowsPowerShell) "This suite runs in Windows PowerShell 5.1"
    $checks++
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Setup tests OK ($checks checks)" -ForegroundColor Green
