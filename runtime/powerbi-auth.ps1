# Shared Power BI authentication for the chained refresh skill.
#
# Two modes, chosen by POWERBI_REFRESH_AUTH_MODE:
#
#   service-principal  App-only certificate credentials. No user interaction and
#                      no token cache on disk. Preferred.
#   delegated          Interactive device-code sign-in for the signed-in Windows
#                      user, persisted through a DPAPI-protected MSAL cache.
#
# Every value is read from local environment variables. No tenant, client, or
# certificate identifier is hardcoded here, and no access token is ever written
# to disk by this module.

$script:PowerBiApiScope = "https://analysis.windows.net/powerbi/api/.default"

# Well-known first-party public client used for the interactive fallback only.
$script:DelegatedClientId = "1950a258-227b-4e31-a9cf-717495945fc2"

$script:ServicePrincipalVariables = @(
    "POWERBI_REFRESH_TENANT_ID"
    "POWERBI_REFRESH_CLIENT_ID"
    "POWERBI_REFRESH_CERT_THUMBPRINT"
)

function Get-PowerBiSafeText {
    # Error text that is safe to log or show: single line, length capped, and with
    # anything token-shaped removed before it reaches a log or a transcript.
    param([AllowNull()][object]$Value)

    $message = if ($Value -is [System.Management.Automation.ErrorRecord]) { $Value.Exception.Message } else { [string]$Value }
    if ([string]::IsNullOrEmpty($message)) { return "" }

    $safe = $message
    $safe = $safe -replace 'eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}', '<redacted-token>'
    $safe = $safe -replace '(?i)\b(client_secret|refresh_token|access_token|client_assertion|assertion|password|sig)\b\s*[=:]\s*\S+', '$1=<redacted>'
    $safe = ($safe -replace '[\r\n]+', ' ').Trim()
    if ($safe.Length -gt 240) { return $safe.Substring(0, 237) + "..." }
    return $safe
}

function Get-PowerBiConfigValue {
    # Reads a configuration value without assuming the process environment block is
    # current, so a variable set after the host started is still picked up.
    param([Parameter(Mandatory = $true)][string]$Name)

    $candidates = @()
    foreach ($scope in @("Process", "User", "Machine")) {
        $value = [Environment]::GetEnvironmentVariable($Name, $scope)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $candidates += [pscustomobject]@{ Scope = $scope; Value = $value.Trim() }
        }
    }
    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{ Name = $Name; Value = $null; Scope = "not set"; StaleProcessCopy = $false }
    }

    $chosen = $candidates[0]
    $stale = $false
    if ($chosen.Scope -eq "Process") {
        $persisted = $candidates | Where-Object { $_.Scope -ne "Process" } | Select-Object -First 1
        if ($persisted) { $stale = ($persisted.Value -ne $chosen.Value) }
    }
    return [pscustomobject]@{ Name = $Name; Value = $chosen.Value; Scope = $chosen.Scope; StaleProcessCopy = $stale }
}

function Test-PowerBiServicePrincipalConfigured {
    foreach ($name in $script:ServicePrincipalVariables) {
        if (-not (Get-PowerBiConfigValue $name).Value) { return $false }
    }
    return $true
}

function Get-PowerBiAuthMode {
    # An explicit POWERBI_REFRESH_AUTH_MODE always wins. Otherwise prefer the
    # service principal as soon as it is fully configured.
    $configured = Get-PowerBiConfigValue "POWERBI_REFRESH_AUTH_MODE"
    if ($configured.Value) {
        switch ($configured.Value.ToLowerInvariant()) {
            "service-principal" { return "service-principal" }
            "delegated" { return "delegated" }
            default {
                throw "POWERBI_REFRESH_AUTH_MODE must be either 'service-principal' or 'delegated'. Current value: '$($configured.Value)'."
            }
        }
    }
    if (Test-PowerBiServicePrincipalConfigured) { return "service-principal" }
    return "delegated"
}

function Import-PowerBiMsalModule {
    try {
        Import-Module MSAL.PS -Force -ErrorAction Stop
    } catch {
        throw "MSAL.PS is required for Power BI authentication. Install it for the current user with 'Install-Module MSAL.PS -Scope CurrentUser', then retry."
    }
}

function Assert-PowerBiCertificateKeyAccess {
    # HasPrivateKey only proves a key reference exists. Windows can still refuse to
    # open it for this process (key bound to another account, or a smart card), so
    # prove the key is usable by actually signing with it.
    param([Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    $key = $null
    try {
        $key = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    } catch {
        $key = $null
    }
    if ($null -eq $key) {
        throw "Certificate $($Certificate.Thumbprint) has a private key, but Windows did not let this process open it. The key most likely belongs to another Windows account or to a smart card. Run the skill as the Windows user that owns the key, or re-import the certificate for Windows user '$([Environment]::UserName)'."
    }

    $verified = $false
    try {
        $probe = New-Object byte[] 32
        (New-Object System.Random).NextBytes($probe)
        $signature = $key.SignData($probe, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $verified = $key.VerifyData($probe, $signature, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } catch {
        $failure = $_.Exception.GetType().Name
        $key.Dispose()
        throw "Certificate $($Certificate.Thumbprint) has a private key that this process cannot use for signing ($failure). Re-import the certificate with its private key into Cert:\CurrentUser\My for Windows user '$([Environment]::UserName)'."
    }
    $key.Dispose()

    if (-not $verified) {
        throw "Certificate $($Certificate.Thumbprint) produced an invalid signature, so its private key cannot be used as-is. Re-import the certificate and its private key."
    }
}

function Get-PowerBiServicePrincipalCertificate {
    param([Parameter(Mandatory = $true)][string]$Thumbprint)

    $normalized = ($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($normalized.Length -ne 40) {
        throw "POWERBI_REFRESH_CERT_THUMBPRINT must be a 40-character SHA-1 certificate thumbprint; the configured value has $($normalized.Length) valid hex characters."
    }

    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("My", "CurrentUser")
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    try {
        # Named storeMatches, not $matches, to avoid clobbering the automatic
        # variable that -match populates.
        $storeMatches = @(
            $store.Certificates |
                Where-Object { ($_.Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant() -eq $normalized }
        )
    } finally {
        $store.Close()
    }

    if ($storeMatches.Count -eq 0) {
        throw "No certificate with thumbprint $normalized exists in Cert:\CurrentUser\My for Windows user '$([Environment]::UserName)'. Import the application certificate together with its private key, then retry."
    }
    if ($storeMatches.Count -gt 1) {
        throw "More than one certificate in Cert:\CurrentUser\My matches thumbprint $normalized. Remove the duplicate, then retry."
    }

    $certificate = $storeMatches[0]
    if (-not $certificate.HasPrivateKey) {
        throw "Certificate $normalized is present but has no private key. Import the certificate with its private key (PFX) into Cert:\CurrentUser\My for Windows user '$([Environment]::UserName)'."
    }

    Assert-PowerBiCertificateKeyAccess -Certificate $certificate
    return $certificate
}

function ConvertTo-PowerBiBase64Url {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    return ([Convert]::ToBase64String($Bytes)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-PowerBiTokenEndpoint {
    param([Parameter(Mandatory = $true)][string]$TenantId)

    return "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
}

function New-PowerBiClientAssertion {
    # Builds and signs an OAuth2 client assertion (RFC 7523) with the certificate's
    # private key.
    #
    # WHY NOT HAND MSAL THE CERTIFICATE DIRECTLY: MSAL.PS 4.37 ships only the net45
    # build of Microsoft.Identity.Client (its manifest pins that path, and no net461
    # build exists in the package; 4.37.0.0 from 2021 is also the module's last
    # release). The net45 build signs through the legacy X509Certificate2.PrivateKey
    # CAPI property, which is null for a CNG key -- the Windows default, provider
    # "Microsoft Software Key Storage Provider". MSAL then fails with "Could not use
    # the certificate for signing" / inner "Invalid provider type specified".
    # Signing here uses RSACertificateExtensions::GetRSAPrivateKey(), which handles
    # CNG keys, while MSAL still performs the token exchange. Do not "simplify" this
    # back to passing -ClientCertificate.
    param(
        [Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$Audience
    )

    $key = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if ($null -eq $key) {
        throw "Certificate $($Certificate.Thumbprint) has a private key that this process cannot open for signing."
    }

    try {
        $now = [DateTimeOffset]::UtcNow
        $header = [ordered]@{
            alg = "RS256"
            typ = "JWT"
            x5t = ConvertTo-PowerBiBase64Url $Certificate.GetCertHash()
        } | ConvertTo-Json -Compress
        $payload = [ordered]@{
            aud = $Audience
            iss = $ClientId
            sub = $ClientId
            jti = [Guid]::NewGuid().ToString()
            nbf = $now.AddMinutes(-2).ToUnixTimeSeconds()
            exp = $now.AddMinutes(10).ToUnixTimeSeconds()
            iat = $now.ToUnixTimeSeconds()
        } | ConvertTo-Json -Compress

        $headerPart = ConvertTo-PowerBiBase64Url ([Text.Encoding]::UTF8.GetBytes($header))
        $payloadPart = ConvertTo-PowerBiBase64Url ([Text.Encoding]::UTF8.GetBytes($payload))
        $signature = $key.SignData(
            [Text.Encoding]::ASCII.GetBytes("$headerPart.$payloadPart"),
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        return "$headerPart.$payloadPart.$(ConvertTo-PowerBiBase64Url $signature)"
    } finally {
        $key.Dispose()
    }
}

function Get-PowerBiServicePrincipalAuthError {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory = $true)][object]$Context
    )

    $text = [string]$ErrorRecord.Exception.ToString()
    $summary = Get-PowerBiSafeText $ErrorRecord

    if ($text -match 'AADSTS700027|AADSTS700023|invalid_client|client assertion|Client assertion') {
        return "Microsoft Entra rejected the client certificate for application $($Context.ClientId) in tenant $($Context.TenantId). Upload the public certificate (.cer) for thumbprint $($Context.CertificateThumbprint) to that app registration, or correct POWERBI_REFRESH_CERT_THUMBPRINT. Entra said: $summary"
    }
    if ($text -match 'AADSTS700016|was not found in the directory') {
        return "Application $($Context.ClientId) was not found in tenant $($Context.TenantId). Check POWERBI_REFRESH_CLIENT_ID and POWERBI_REFRESH_TENANT_ID. Entra said: $summary"
    }
    if ($text -match 'AADSTS65001|AADSTS500011') {
        return "Tenant $($Context.TenantId) has not granted consent for the Power BI service permissions on application $($Context.ClientId). Ask a tenant administrator to grant admin consent for the Power BI Service API. Entra said: $summary"
    }
    if ($text -match 'AADSTS7000215|invalid client secret') {
        return "Microsoft Entra expected a client secret instead of a certificate for application $($Context.ClientId). This skill uses certificate authentication only; use the certificate configured in the app registration's Certificates and secrets blade. Entra said: $summary"
    }
    if ($text -match 'AADSTS50034|AADSTS90002|tenant .* not found') {
        return "Tenant $($Context.TenantId) could not be resolved. Check POWERBI_REFRESH_TENANT_ID. Entra said: $summary"
    }
    return "Service-principal authentication failed for application $($Context.ClientId) in tenant $($Context.TenantId). Entra said: $summary"
}

function Get-PowerBiDelegatedAuthError {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [switch]$ForceRefresh
    )

    $text = [string]$ErrorRecord.Exception.ToString()
    if ($text -match 'could not be decrypted') {
        return "The Power BI refresh skill's local sign-in cache could not be decrypted. Run scripts\connect-powerbi-refresh.ps1 from a normal Windows PowerShell window to create a new cache, then rerun the refresh."
    }
    if ($ForceRefresh) {
        return "Power BI authorization could not be silently renewed. Your Microsoft Entra session may have been revoked by policy or now require renewed MFA. Run scripts\connect-powerbi-refresh.ps1 from a normal Windows PowerShell window, complete sign-in, then rerun the refresh."
    }
    return "Power BI sign-in is required once. Run scripts\connect-powerbi-refresh.ps1 from a normal Windows PowerShell window, complete the device-code sign-in, then retry this command."
}

function New-PowerBiAuthContext {
    # Resolves configuration and builds the MSAL client once per process. Accepts
    # no secret values: everything comes from the environment.
    Import-PowerBiMsalModule
    $mode = Get-PowerBiAuthMode

    if ($mode -eq "service-principal") {
        $missing = @()
        foreach ($name in $script:ServicePrincipalVariables) {
            if (-not (Get-PowerBiConfigValue $name).Value) { $missing += $name }
        }
        if ($missing.Count -gt 0) {
            throw "Service-principal authentication needs these environment variables: $($missing -join ', '). Set them as user environment variables, then open a new terminal."
        }

        $tenantId = (Get-PowerBiConfigValue "POWERBI_REFRESH_TENANT_ID").Value
        $clientId = (Get-PowerBiConfigValue "POWERBI_REFRESH_CLIENT_ID").Value
        $thumbprint = (Get-PowerBiConfigValue "POWERBI_REFRESH_CERT_THUMBPRINT").Value

        foreach ($pair in @(@("POWERBI_REFRESH_TENANT_ID", $tenantId), @("POWERBI_REFRESH_CLIENT_ID", $clientId))) {
            $parsed = [Guid]::Empty
            if (-not [Guid]::TryParse($pair[1], [ref]$parsed)) {
                throw "$($pair[0]) is not a valid GUID. Use the directory (tenant) ID and the application (client) ID from the app registration's Overview blade."
            }
        }

        $certificate = Get-PowerBiServicePrincipalCertificate -Thumbprint $thumbprint
        $tokenEndpoint = Get-PowerBiTokenEndpoint $tenantId
        $assertion = New-PowerBiClientAssertion -Certificate $certificate -ClientId $clientId -Audience $tokenEndpoint
        try {
            $client = New-MsalClientApplication -ClientId $clientId -TenantId $tenantId -ClientAssertion $assertion -ErrorAction Stop
        } catch {
            throw "The service-principal client could not be created from certificate $($certificate.Thumbprint): $(Get-PowerBiSafeText $_)"
        }

        return [pscustomobject]@{
            Mode = "service-principal"
            Client = $client
            Certificate = $certificate
            ClientId = $clientId
            TenantId = $tenantId
            TokenEndpoint = $tokenEndpoint
            CertificateThumbprint = $certificate.Thumbprint
            Scopes = $script:PowerBiApiScope
            UsesInteractiveSignIn = $false
        }
    }

    # Delegated fallback: interactive device-code sign-in for the signed-in Windows
    # user, persisted through the DPAPI-protected cache in powerbi-msal-cache.ps1.
    # The cache is loaded only here, so certificate mode never touches it.
    . (Join-Path $PSScriptRoot "powerbi-msal-cache.ps1")
    $client = New-MsalClientApplication -ClientId $script:DelegatedClientId -TenantId "common" -ErrorAction Stop
    Enable-PowerBiChainedRefreshTokenCache -PublicClientApplication $client | Out-Null

    return [pscustomobject]@{
        Mode = "delegated"
        Client = $client
        Certificate = $null
        ClientId = $script:DelegatedClientId
        TenantId = "common"
        TokenEndpoint = ""
        CertificateThumbprint = ""
        Scopes = $script:PowerBiApiScope
        UsesInteractiveSignIn = $true
    }
}

function Get-PowerBiAccessToken {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [switch]$ForceRefresh
    )

    if ($Context.Mode -eq "service-principal") {
        # A client assertion is short-lived (10 minutes) and MSAL treats whatever it
        # was constructed with as a static credential, so rebuild both the assertion
        # and the client for every token request. Signing is local and cheap, and it
        # guarantees the scheduled renewal and any 401 retry never present a stale
        # assertion.
        $assertion = New-PowerBiClientAssertion -Certificate $Context.Certificate -ClientId $Context.ClientId -Audience $Context.TokenEndpoint
        try {
            $client = New-MsalClientApplication -ClientId $Context.ClientId -TenantId $Context.TenantId -ClientAssertion $assertion -ErrorAction Stop
        } catch {
            throw "The service-principal client could not be created from certificate $($Context.CertificateThumbprint): $(Get-PowerBiSafeText $_)"
        }
        try {
            $result = Get-MsalToken -ConfidentialClientApplication $client -Scopes $Context.Scopes -ForceRefresh -ErrorAction Stop
        } catch {
            throw (Get-PowerBiServicePrincipalAuthError -ErrorRecord $_ -Context $Context)
        }
    } else {
        $request = @{
            PublicClientApplication = $Context.Client
            Scopes = $Context.Scopes
            Silent = $true
            ErrorAction = "Stop"
        }
        if ($ForceRefresh) { $request.ForceRefresh = $true }
        try {
            $result = Get-MsalToken @request
        } catch {
            throw (Get-PowerBiDelegatedAuthError -ErrorRecord $_ -ForceRefresh:$ForceRefresh)
        }
    }

    $token = [string]$result.AccessToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Power BI authentication returned an empty access token."
    }
    return $token
}
