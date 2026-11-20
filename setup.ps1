<#
.SYNOPSIS
    Per-user setup for the Power BI Dashboard Control Panel. Needs no admin rights.

.DESCRIPTION
    Run it through setup.bat. Safe to run again: every step checks the current state first
    and changes only what is missing or different.

    1. Unblocks the files in this folder (downloaded ZIPs mark them as blocked).
    2. Checks Windows PowerShell 5.1 and Microsoft Edge.
    3. Installs MSAL.PS for the current user without the NuGet and PSGallery prompts.
    4. Sign-in: device code. Only when a working certificate is already set up on this PC
       (the three certificate variables and the certificate with its private key in
       Cert:\CurrentUser\My) does setup suggest using it. Setup never creates, imports or
       exports a certificate.
    5. Optionally saves the Power Automate flow URL as the user variable
       REFRESH_EMAIL_WEBHOOK_URL. The URL is never written to a file.
    6. Creates Desktop and Start menu shortcuts to launch-app.bat.
    7. Runs a read-only readiness check, then opens the panel.

.PARAMETER SignIn
    DeviceCode or Certificate. Answers the certificate question in advance. Certificate
    takes effect only when a working certificate is already set up; otherwise device code
    is used.

.PARAMETER SkipWebhook
    Does not ask for the Power Automate flow URL.

.PARAMETER NoLaunch
    Does not open the panel at the end.

.PARAMETER CheckOnly
    Runs only the read-only readiness check.

.PARAMETER DryRun
    Shows what setup would change without changing anything.
#>
[CmdletBinding()]
param(
    [ValidateSet("", "DeviceCode", "Certificate")]
    [string]$SignIn = "",
    [switch]$SkipWebhook,
    [switch]$NoLaunch,
    [switch]$CheckOnly,
    [switch]$DryRun
)

$script:SetupRoot = $PSScriptRoot
$script:SetupDryRun = [bool]$DryRun
$script:SetupChanges = New-Object System.Collections.Generic.List[string]
$script:SetupSignInChanged = $false
$script:SetupAppName = "Power BI Control Panel"
$script:SetupPanelPort = 8765
$script:SetupWebhookVariable = "REFRESH_EMAIL_WEBHOOK_URL"

# The shared sign-in module: the readiness check asks it which mode this PC uses and
# whether the certificate works, exactly as the panel and the refresh runner will.
. (Join-Path $PSScriptRoot "runtime\powerbi-auth.ps1")

# ------------------------------------------------------------------------------------
# Output
# ------------------------------------------------------------------------------------
function Write-SetupStep([string]$Text) { Write-Host ""; Write-Host $Text -ForegroundColor Cyan }
function Write-SetupOk([string]$Text) { Write-Host "  OK    $Text" -ForegroundColor Green }
function Write-SetupInfo([string]$Text) { Write-Host "        $Text" -ForegroundColor Gray }
function Write-SetupWarn([string]$Text) { Write-Host "  NOTE  $Text" -ForegroundColor Yellow }
function Write-SetupFail([string]$Text) { Write-Host "  FAIL  $Text" -ForegroundColor Red }

function Invoke-SetupChange {
    # Every change goes through here, so -DryRun can report it instead of doing it.
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    if ($script:SetupDryRun) {
        Write-Host "  DRY   Would $Description" -ForegroundColor Magenta
        $script:SetupChanges.Add("would: $Description")
        return $null
    }
    $result = & $Action
    Write-SetupOk ($Description.Substring(0, 1).ToUpperInvariant() + $Description.Substring(1))
    $script:SetupChanges.Add($Description)
    return $result
}

# ------------------------------------------------------------------------------------
# Input (kept in small functions so the tests can answer them)
# ------------------------------------------------------------------------------------
function Read-SetupLine([string]$Prompt) { return [string](Read-Host $Prompt) }

function Read-SetupSecret([string]$Prompt) {
    $secure = Read-Host $Prompt -AsSecureString
    if ($null -eq $secure -or $secure.Length -eq 0) { return "" }
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

# ------------------------------------------------------------------------------------
# Environment probes (read-only)
# ------------------------------------------------------------------------------------
function Test-SetupWindowsPowerShell {
    return ($PSVersionTable.PSEdition -ne "Core" -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -ge 1)
}

function Find-SetupEdge {
    # Same search order as Find-EdgePath in server.ps1.
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe"),
        (Join-Path $env:ProgramFiles "Microsoft\Edge\Application\msedge.exe"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\Edge\Application\msedge.exe")
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    try {
        $appPath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe" -ErrorAction Stop).'(default)'
        if ($appPath -and (Test-Path -LiteralPath $appPath)) { return $appPath }
    } catch { }
    return $null
}

function Get-SetupBlockedFiles([string]$Root) {
    # A file downloaded from the internet carries a Zone.Identifier stream.
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch '[\\/]\.git[\\/]' -and
            (Get-Item -LiteralPath $_.FullName -Stream "Zone.Identifier" -ErrorAction SilentlyContinue)
        })
}

function Repair-SetupModulePath {
    # Same rule as server.ps1: started from a PowerShell 7 shell, Windows PowerShell inherits
    # a module path that misses its own user module folder. Changes this process only.
    if ($PSVersionTable.PSEdition -eq "Core") { return }
    $windowsDirs = @(
        (Join-Path ([Environment]::GetFolderPath("MyDocuments")) "WindowsPowerShell\Modules"),
        (Join-Path $env:ProgramFiles "WindowsPowerShell\Modules"),
        (Join-Path $PSHOME "Modules")
    )
    $otherDirs = @($env:PSModulePath -split ';' | Where-Object {
        $_ -and
        ($windowsDirs -notcontains $_.TrimEnd('\')) -and
        $_ -notmatch '\\PowerShell\\(Modules|7)' -and
        $_ -notmatch '\\Microsoft\.PowerShell_[^\\]+\\Modules'
    })
    $env:PSModulePath = (@($windowsDirs) + $otherDirs) -join ';'
}

function Test-SetupMsalModule {
    return [bool](Get-Module -ListAvailable -Name "MSAL.PS" -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Get-SetupVariable([string]$Name) {
    # Process, User, then Machine, as the sign-in module reads it.
    return (Get-PowerBiConfigValue $Name).Value
}

function Get-SetupCertificateState {
    # A certificate counts as detected only when it is already fully set up on this PC: the
    # three certificate variables are set, and the certificate they name is in
    # Cert:\CurrentUser\My with a private key this user can sign with, and has not expired.
    # Setup never creates, imports or exports a certificate. Read-only.
    $set = @($script:ServicePrincipalVariables | Where-Object { Get-SetupVariable $_ })
    if ($set.Count -eq 0) { return [pscustomobject]@{ Certificate = $null; Problem = "" } }
    if ($set.Count -lt $script:ServicePrincipalVariables.Count) {
        $missing = @($script:ServicePrincipalVariables | Where-Object { $set -notcontains $_ })
        return [pscustomobject]@{ Certificate = $null; Problem = "these variables are missing: $($missing -join ', ')" }
    }
    try {
        $certificate = Get-PowerBiServicePrincipalCertificate -Thumbprint (Get-SetupVariable "POWERBI_REFRESH_CERT_THUMBPRINT")
    } catch {
        return [pscustomobject]@{ Certificate = $null; Problem = (Get-PowerBiSafeText $_) }
    }
    if ($certificate.NotAfter -le (Get-Date)) {
        return [pscustomobject]@{ Certificate = $null; Problem = "the certificate expired on $($certificate.NotAfter.ToString('yyyy-MM-dd'))" }
    }
    return [pscustomobject]@{ Certificate = $certificate; Problem = "" }
}

function Test-SetupPanelRunning {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $attempt = $client.BeginConnect("127.0.0.1", $script:SetupPanelPort, $null, $null)
        if (-not $attempt.AsyncWaitHandle.WaitOne(300)) { return $false }
        $client.EndConnect($attempt)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-SetupShortcutPaths {
    $name = "$($script:SetupAppName).lnk"
    return @(
        (Join-Path ([Environment]::GetFolderPath("Desktop")) $name),
        (Join-Path ([Environment]::GetFolderPath("Programs")) $name)
    )
}

function Get-SetupIconPath { return (Join-Path $env:LOCALAPPDATA "PowerBIControlPanel\app.ico") }

function Test-SetupShortcut {
    param([string]$Path, [string]$Target, [string]$IconPath)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Path)
    return ($link.TargetPath -eq $Target -and $link.IconLocation -eq "$IconPath,0")
}

# ------------------------------------------------------------------------------------
# Changes (each one is called only through Invoke-SetupChange)
# ------------------------------------------------------------------------------------
function Unblock-SetupFiles([object[]]$Files) {
    foreach ($file in $Files) { Unblock-File -LiteralPath $file.FullName }
}

function Install-SetupMsalModule {
    # -Force answers both prompts: the NuGet provider bootstrap and the untrusted PSGallery.
    # The gallery's trust setting itself is left unchanged.
    $ProgressPreference = "SilentlyContinue"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $nuget = Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue |
        Where-Object { $_.Version -ge [version]"2.8.5.201" } | Select-Object -First 1
    if (-not $nuget) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ForceBootstrap -ErrorAction Stop | Out-Null
    }
    $installParams = @{
        Name = "MSAL.PS"
        Scope = "CurrentUser"
        Repository = "PSGallery"
        Force = $true
        AllowClobber = $true
        ErrorAction = "Stop"
    }
    # PowerShellGet 2.x asks to accept the module's license unless told it is accepted;
    # the 1.0 version built into Windows has no such prompt or parameter.
    if ((Get-Command Install-Module).Parameters.ContainsKey("AcceptLicense")) { $installParams.AcceptLicense = $true }
    Install-Module @installParams
}

function Set-SetupUserVariable([string]$Name, [string]$Value) {
    [Environment]::SetEnvironmentVariable($Name, $Value, "User")
    # The current process keeps its old copy otherwise, and the readiness check reads it.
    [Environment]::SetEnvironmentVariable($Name, $Value, "Process")
}

function Get-SetupIconBytes([string]$PngPath) {
    # An .ico file with one PNG image inside (supported since Windows Vista).
    $png = [System.IO.File]::ReadAllBytes($PngPath)
    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($stream)
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]1)
    $writer.Write([byte]([int]$png[19] % 256)); $writer.Write([byte]([int]$png[23] % 256))
    $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]1); $writer.Write([uint16]32)
    $writer.Write([uint32]$png.Length); $writer.Write([uint32]22)
    $writer.Write($png)
    $writer.Flush()
    $bytes = $stream.ToArray()
    $writer.Dispose()
    return ,$bytes
}

function Write-SetupIcon([string]$PngPath, [string]$IcoPath) {
    $folder = Split-Path -Parent $IcoPath
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($IcoPath, (Get-SetupIconBytes $PngPath))
}

function New-SetupShortcut {
    param([string]$Path, [string]$Target, [string]$WorkingDirectory, [string]$IconPath)
    $folder = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Path)
    $link.TargetPath = $Target
    $link.WorkingDirectory = $WorkingDirectory
    $link.IconLocation = "$IconPath,0"
    $link.WindowStyle = 7
    $link.Description = "Power BI Dashboard Control Panel"
    $link.Save()
}

function Start-SetupPanel([string]$Root) {
    Start-Process -FilePath (Join-Path $Root "launch-app.bat") -WorkingDirectory $Root -WindowStyle Minimized
}

# ------------------------------------------------------------------------------------
# Steps
# ------------------------------------------------------------------------------------
function Invoke-SetupUnblock {
    Write-SetupStep "Unblocking the files in this folder"
    $blocked = @(Get-SetupBlockedFiles $script:SetupRoot)
    if ($blocked.Count -eq 0) { Write-SetupOk "No blocked files"; return }
    try {
        Invoke-SetupChange "unblock $($blocked.Count) file(s)" { Unblock-SetupFiles $blocked } | Out-Null
    } catch {
        Write-SetupWarn "Could not unblock the files: $(Get-PowerBiSafeText $_). Unblock the ZIP before unzipping it (right-click > Properties > Unblock)."
    }
}

function Invoke-SetupMsal {
    Write-SetupStep "Checking MSAL.PS (the sign-in module)"
    Repair-SetupModulePath
    if (Test-SetupMsalModule) { Write-SetupOk "MSAL.PS is installed"; return }
    Write-SetupInfo "Installing MSAL.PS for the current user from the PowerShell Gallery. This takes about a minute."
    try {
        Invoke-SetupChange "install MSAL.PS for the current user" { Install-SetupMsalModule } | Out-Null
    } catch {
        Write-SetupFail "MSAL.PS could not be installed: $(Get-PowerBiSafeText $_)"
        Write-SetupInfo "Check the internet connection or a proxy, then run setup.bat again. Rebind works without it."
    }
}

function Read-SetupUseCertificate($Certificate) {
    Write-Host ""
    Write-Host "  This PC already has a working certificate for sign-in:" -ForegroundColor White
    Write-SetupInfo "$($Certificate.Subject), expires $($Certificate.NotAfter.ToString('yyyy-MM-dd'))."
    Write-SetupInfo "With it, refreshes sign in as the app, without a person (for unattended PCs)."
    Write-SetupInfo "Without it, you sign in with your own account using a code (device code)."
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $answer = (Read-SetupLine "  Use the certificate? [Y/n]").Trim().ToLowerInvariant()
        if ($answer -eq "" -or $answer -eq "y" -or $answer -eq "yes") { return $true }
        if ($answer -eq "n" -or $answer -eq "no") { return $false }
        Write-SetupWarn "Type y or n."
    }
    return $true
}

function Set-SetupAuthMode([string]$Mode) {
    if ((Get-SetupVariable "POWERBI_REFRESH_AUTH_MODE") -eq $Mode) { return }
    Invoke-SetupChange "set the user variable POWERBI_REFRESH_AUTH_MODE to $Mode" { Set-SetupUserVariable "POWERBI_REFRESH_AUTH_MODE" $Mode } | Out-Null
    $script:SetupSignInChanged = $true
}

function Invoke-SetupSignIn {
    # Device code unless a working certificate is already set up and the person keeps it.
    param([string]$Choice)

    Write-SetupStep "Sign-in"
    $state = Get-SetupCertificateState
    $useCertificate = $false
    if ($state.Certificate) {
        if ($Choice -eq "Certificate") { $useCertificate = $true }
        elseif ($Choice -eq "DeviceCode") { $useCertificate = $false }
        else { $useCertificate = Read-SetupUseCertificate $state.Certificate }
    } else {
        if ($state.Problem) { Write-SetupWarn "Certificate settings were found, but they cannot be used: $($state.Problem)" }
        if ($Choice -eq "Certificate") { Write-SetupWarn "No working certificate is set up on this PC, so device code is used. Setup does not create certificates." }
    }

    if ($useCertificate) {
        # Without POWERBI_REFRESH_AUTH_MODE the certificate is chosen already; only an
        # explicit other value has to change.
        $current = Get-SetupVariable "POWERBI_REFRESH_AUTH_MODE"
        if ($current -and $current -ne "service-principal") { Set-SetupAuthMode "service-principal" }
        Write-SetupOk "Sign-in: certificate ($($state.Certificate.Subject))"
        return
    }

    # Device code. Nothing to set unless certificate settings would otherwise win.
    $mode = $null
    try { $mode = Get-PowerBiAuthMode } catch { $mode = $null }
    if ($mode -ne "delegated") { Set-SetupAuthMode "delegated" }
    Write-SetupOk "Sign-in: device code. Sign in from the panel with Authenticate for Refresh."
}

function Invoke-SetupWebhook {
    Write-SetupStep "Email notifications (optional)"
    $existing = Get-SetupVariable $script:SetupWebhookVariable
    Write-SetupInfo "Paste the Power Automate flow URL you received privately. The input stays hidden."
    $prompt = if ($existing) { "  A flow URL is already saved. Paste a new one, or press Enter to keep it" } else { "  Flow URL, or press Enter to skip" }
    $url = (Read-SetupSecret $prompt).Trim()
    try {
        if (-not $url) {
            if ($existing) { Write-SetupOk "Kept the saved flow URL" } else { Write-SetupInfo "Skipped. Refreshes run without email; run setup.bat again to add it later." }
            return
        }
        if ($url -notmatch '^https://[^\s/]+/\S+$') {
            Write-SetupWarn "That does not look like a flow URL (it must start with https://). Nothing was saved."
            return
        }
        if ($url -notmatch '/workflows/') {
            Write-SetupWarn "The URL has no '/workflows/' part. It is saved, but check that it is the flow's HTTP POST URL."
        }
        if ($url -eq $existing) { Write-SetupOk "The same flow URL is already saved"; return }
        $value = $url
        Invoke-SetupChange "save the flow URL as the user variable $($script:SetupWebhookVariable)" { Set-SetupUserVariable $script:SetupWebhookVariable $value } | Out-Null
    } finally {
        $url = $null; $value = $null
    }
}

function Invoke-SetupShortcuts {
    Write-SetupStep "Shortcuts"
    $iconPath = Get-SetupIconPath
    $pngPath = Join-Path $script:SetupRoot "favicon.png"
    $target = Join-Path $script:SetupRoot "launch-app.bat"
    $iconCurrent = $false
    if (Test-Path -LiteralPath $iconPath) {
        $expected = [Convert]::ToBase64String((Get-SetupIconBytes $pngPath))
        $iconCurrent = ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($iconPath)) -eq $expected)
    }
    if ($iconCurrent) { Write-SetupOk "App icon is in place" }
    else { Invoke-SetupChange "write the app icon to $iconPath" { Write-SetupIcon $pngPath $iconPath } | Out-Null }

    foreach ($path in (Get-SetupShortcutPaths)) {
        if (Test-SetupShortcut -Path $path -Target $target -IconPath $iconPath) { Write-SetupOk "Shortcut already in place: $path"; continue }
        $shortcutPath = $path
        Invoke-SetupChange "create the shortcut $shortcutPath" {
            New-SetupShortcut -Path $shortcutPath -Target $target -WorkingDirectory $script:SetupRoot -IconPath $iconPath
        } | Out-Null
    }
}

# ------------------------------------------------------------------------------------
# Readiness (read-only)
# ------------------------------------------------------------------------------------
function Get-SetupReadiness {
    $items = New-Object System.Collections.Generic.List[object]
    $add = { param($Name, $Status, $Detail) $items.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail }) }

    if (Test-SetupWindowsPowerShell) { & $add "Windows PowerShell" "OK" "version $($PSVersionTable.PSVersion)" }
    else { & $add "Windows PowerShell" "FAIL" "needs Windows PowerShell 5.1; this is $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion). Start setup.bat instead." }

    $blocked = @(Get-SetupBlockedFiles $script:SetupRoot)
    if ($blocked.Count -eq 0) { & $add "Files" "OK" "not blocked" }
    else { & $add "Files" "FAIL" "$($blocked.Count) file(s) are still blocked; run setup.bat again or unblock the ZIP before unzipping" }

    $edge = Find-SetupEdge
    if ($edge) { & $add "Microsoft Edge" "OK" "found" }
    else { & $add "Microsoft Edge" "WARN" "not found; the panel opens in the default browser instead" }

    Repair-SetupModulePath
    $msal = Test-SetupMsalModule
    if ($msal) { & $add "MSAL.PS" "OK" "installed" }
    else { & $add "MSAL.PS" "FAIL" "not installed; Refresh cannot sign in (Rebind still works). Run setup.bat again." }

    $mode = $null
    try { $mode = Get-PowerBiAuthMode } catch { & $add "Sign-in" "FAIL" (Get-PowerBiSafeText $_) }
    if ($mode -eq "service-principal") {
        $missing = @($script:ServicePrincipalVariables | Where-Object { -not (Get-SetupVariable $_) })
        if ($missing.Count -gt 0) {
            & $add "Sign-in" "FAIL" "certificate mode, but these user variables are missing: $($missing -join ', ')"
        } else {
            try {
                $certificate = Get-PowerBiServicePrincipalCertificate -Thumbprint (Get-SetupVariable "POWERBI_REFRESH_CERT_THUMBPRINT")
                $days = [int][Math]::Floor(($certificate.NotAfter - (Get-Date)).TotalDays)
                if ($days -lt 0) { & $add "Sign-in" "FAIL" "certificate expired on $($certificate.NotAfter.ToString('yyyy-MM-dd')); run setup.bat and choose certificate again" }
                elseif ($days -lt 30) { & $add "Sign-in" "WARN" "certificate, expires in $days days ($($certificate.NotAfter.ToString('yyyy-MM-dd')))" }
                else { & $add "Sign-in" "OK" "certificate, key usable, expires $($certificate.NotAfter.ToString('yyyy-MM-dd')). Whether the app owner uploaded it shows at the first sign-in." }
            } catch {
                & $add "Sign-in" "FAIL" "certificate mode: $(Get-PowerBiSafeText $_)"
            }
        }
    } elseif ($mode -eq "delegated") {
        $partial = @($script:ServicePrincipalVariables | Where-Object { Get-SetupVariable $_ })
        $detail = "device code; sign in from the panel with Authenticate for Refresh"
        if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA "PowerBIChainedRefresh\msalcache.bin3")) {
            $detail = "device code; a saved sign-in exists and is checked when the panel starts"
        }
        if ($partial.Count -gt 0 -and $partial.Count -lt 3) {
            & $add "Sign-in" "WARN" "$detail. Some certificate variables are set but not all: $($partial -join ', ')"
        } else {
            & $add "Sign-in" "OK" $detail
        }
    }

    $webhook = Get-SetupVariable $script:SetupWebhookVariable
    if (-not $webhook) { & $add "Email" "INFO" "no flow URL; refreshes run without email (dry run still works)" }
    elseif ($webhook -notmatch '^https://') { & $add "Email" "WARN" "$($script:SetupWebhookVariable) does not start with https://" }
    else { & $add "Email" "OK" "flow URL saved as a user variable" }

    $iconPath = Get-SetupIconPath
    $target = Join-Path $script:SetupRoot "launch-app.bat"
    $missingLinks = @(Get-SetupShortcutPaths | Where-Object { -not (Test-SetupShortcut -Path $_ -Target $target -IconPath $iconPath) })
    if ($missingLinks.Count -eq 0) { & $add "Shortcuts" "OK" "Desktop and Start menu" }
    else { & $add "Shortcuts" "INFO" "missing or pointing elsewhere: $($missingLinks -join '; ')" }

    $ready = -not ($items | Where-Object { $_.Status -eq "FAIL" })
    return [pscustomobject]@{ Ready = [bool]$ready; Items = $items.ToArray() }
}

function Write-SetupReadiness($Readiness) {
    Write-SetupStep "Readiness check (read-only)"
    foreach ($item in $Readiness.Items) {
        $color = switch ($item.Status) { "OK" { "Green" } "INFO" { "Gray" } "WARN" { "Yellow" } default { "Red" } }
        Write-Host ("  {0,-5} {1,-19} {2}" -f $item.Status, $item.Name, $item.Detail) -ForegroundColor $color
    }
    Write-Host ""
    if ($Readiness.Ready) {
        Write-Host "  Ready" -ForegroundColor Green
    } else {
        Write-Host "  Not ready:" -ForegroundColor Red
        foreach ($item in ($Readiness.Items | Where-Object { $_.Status -eq "FAIL" })) {
            Write-Host "    - $($item.Name): $($item.Detail)" -ForegroundColor Red
        }
    }
}

# ------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------
function Invoke-Setup {
    param(
        [string]$SignIn,
        [switch]$SkipWebhook,
        [switch]$NoLaunch,
        [switch]$CheckOnly
    )

    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "  Power BI Dashboard Control Panel - setup" -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-SetupInfo "Folder: $($script:SetupRoot)"
    if ($script:SetupDryRun) { Write-Host "  Dry run: nothing is changed." -ForegroundColor Magenta }

    if ($CheckOnly) {
        $readiness = Get-SetupReadiness
        Write-SetupReadiness $readiness
        return $readiness
    }

    Write-SetupStep "Checking Windows PowerShell and Microsoft Edge"
    if (-not (Test-SetupWindowsPowerShell)) {
        Write-SetupFail "This needs Windows PowerShell 5.1 (built into Windows). Start setup.bat instead of running setup.ps1 from PowerShell 7."
        return [pscustomobject]@{ Ready = $false; Items = @() }
    }
    Write-SetupOk "Windows PowerShell $($PSVersionTable.PSVersion)"
    if (Find-SetupEdge) { Write-SetupOk "Microsoft Edge found" }
    else { Write-SetupWarn "Microsoft Edge was not found. The panel will open in the default browser." }

    $panelWasRunning = Test-SetupPanelRunning

    Invoke-SetupUnblock
    Invoke-SetupMsal
    Invoke-SetupSignIn -Choice $SignIn
    if (-not $SkipWebhook) { Invoke-SetupWebhook }
    Invoke-SetupShortcuts

    $readiness = Get-SetupReadiness
    Write-SetupReadiness $readiness

    Write-Host ""
    if ($script:SetupDryRun) {
        Write-Host "  Dry run finished: $($script:SetupChanges.Count) change(s) would be made." -ForegroundColor Magenta
        return $readiness
    }
    if ($panelWasRunning -and $script:SetupSignInChanged) {
        Write-SetupWarn "The panel was already running. Close its window and start it again so it uses the new sign-in settings."
    }
    if (-not $NoLaunch) {
        Write-SetupInfo "Opening the panel. Next: sign in (Authenticate for Refresh) and create a profile."
        Start-SetupPanel $script:SetupRoot
    } else {
        Write-SetupInfo "Next: start the panel from the Desktop shortcut, sign in and create a profile."
    }
    return $readiness
}

if ($MyInvocation.InvocationName -ne ".") {
    $outcome = Invoke-Setup -SignIn $SignIn -SkipWebhook:$SkipWebhook -NoLaunch:$NoLaunch -CheckOnly:$CheckOnly
    if ($outcome.Ready) { exit 0 } else { exit 2 }
}
