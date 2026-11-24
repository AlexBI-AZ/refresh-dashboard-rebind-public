# Sends one email through the Power Automate flow at REFRESH_EMAIL_WEBHOOK_URL.
# The email itself is built by New-ValidationEmailContent in validation\validation.ps1:
# every refresh, from the Control Panel, the Claude skill or the validated refresh, sends
# that one format (the refresh table and the before/after checks of each semantic model).
#
# How the flow admits the call depends on its trigger setting "Who can trigger the flow?":
#   Anyone                      the key in the URL (its sig parameter) is the only check.
#   Any user in my tenant,      the call must carry a Microsoft Entra access token for the
#   Specific users in my tenant flow service (audience https://service.flow.microsoft.com/).
# A URL key and a token in one call are refused, so a URL without a sig key is sent with a
# token, and a URL with one is sent as it is. Only if the flow refuses that call (401 or
# 403: the flow did not start, so nothing is sent twice) is it sent once more with a
# token, to the same URL without its key (sp, sv, sig). A token is only ever sent over
# HTTPS to a Power Automate host.
#
# The token comes from the same sign-in as the refresh (runtime\powerbi-auth.ps1, which
# must already be loaded): the certificate app, or the device-code sign-in kept in the
# MSAL cache. It is requested only when the flow needs it.

$script:RefreshFlowScope = "https://service.flow.microsoft.com//.default"
$script:RefreshFlowHostSuffixes = @(".logic.azure.com", ".api.powerplatform.com")
$script:RefreshFlowKeyParameters = @("sp", "sv", "sig")

function Test-RefreshFlowUrlHasKey {
    # True when the trigger URL carries a sig key (an "Anyone" trigger).
    param([Parameter(Mandatory = $true)][string]$Url)

    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $false }
    foreach ($pair in $uri.Query.TrimStart('?').Split('&')) {
        if ($pair.Split('=')[0] -ieq "sig") { return $true }
    }
    return $false
}

function Get-RefreshFlowUrlWithoutKey {
    # The trigger URL without its shared-access key parameters, for a call that signs in.
    param([Parameter(Mandatory = $true)][string]$Url)

    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or [string]::IsNullOrEmpty($uri.Query)) { return $Url }
    $kept = @($uri.Query.TrimStart('?').Split('&') | Where-Object {
        $_ -ne "" -and $script:RefreshFlowKeyParameters -notcontains $_.Split('=')[0].ToLowerInvariant()
    })
    $builder = New-Object System.UriBuilder $uri
    $builder.Query = $kept -join '&'
    return $builder.Uri.AbsoluteUri
}

function Test-RefreshFlowTrustedHost {
    # True for an HTTPS URL on a Power Automate trigger host, the only place a token may go.
    param([Parameter(Mandatory = $true)][string]$Url)

    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -ne "https") { return $false }
    $hostName = $uri.Host.ToLowerInvariant()
    foreach ($suffix in $script:RefreshFlowHostSuffixes) {
        if ($hostName.EndsWith($suffix) -and $hostName.Length -gt $suffix.Length) { return $true }
    }
    return $false
}

function Get-RefreshFlowAccessToken {
    # A token for the flow service from the refresh's own sign-in context
    # (New-PowerBiAuthContext): app-only with the certificate, or silently from the
    # device-code cache. Never interactive.
    param([Parameter(Mandatory = $true)][object]$Context)

    try {
        if ($Context.Mode -eq "service-principal") {
            $assertion = New-PowerBiClientAssertion -Certificate $Context.Certificate -ClientId $Context.ClientId -Audience $Context.TokenEndpoint
            $client = New-MsalClientApplication -ClientId $Context.ClientId -TenantId $Context.TenantId -ClientAssertion $assertion -ErrorAction Stop
            $result = Get-MsalToken -ConfidentialClientApplication $client -Scopes $script:RefreshFlowScope -ErrorAction Stop
        } else {
            $result = Get-MsalToken -PublicClientApplication $Context.Client -Scopes $script:RefreshFlowScope -Silent -ErrorAction Stop
        }
    } catch {
        $reason = Get-PowerBiSafeText $_
        $hint = if ($Context.Mode -eq "service-principal") {
            "The certificate app may need a permission for the Power Automate service, or a tenant policy blocks it."
        } else {
            "Sign in again from the Refresh tab; if that does not help, the tenant does not let this sign-in get a Power Automate token without consent, and the flow trigger has to stay on Anyone."
        }
        throw "The flow only accepts signed-in callers, and a Power Automate token could not be obtained ($($Context.Mode) sign-in). $hint Entra said: $reason"
    }
    $token = [string]$result.AccessToken
    if ([string]::IsNullOrWhiteSpace($token)) { throw "Power Automate sign-in returned an empty access token." }
    return $token
}

function Get-RefreshFlowHttpStatus {
    # The HTTP status of a failed call, or 0 when there was no response.
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $response = $ErrorRecord.Exception.Response
    if ($null -ne $response -and $null -ne $response.StatusCode) { return [int]$response.StatusCode }
    return 0
}

function Get-RefreshFlowAuthorizationHeader {
    param(
        [Parameter(Mandatory = $true)][string]$WebhookUrl,
        [AllowNull()][scriptblock]$GetAccessToken
    )

    if (-not (Test-RefreshFlowTrustedHost $WebhookUrl)) {
        throw "The flow only accepts signed-in callers, but its URL is not an HTTPS Power Automate address (*.logic.azure.com or *.api.powerplatform.com), so no token was sent. Check REFRESH_EMAIL_WEBHOOK_URL."
    }
    if ($null -eq $GetAccessToken) {
        throw "The flow only accepts signed-in callers, and no Power Automate sign-in is available here. Set the flow trigger to Anyone or send from the Control Panel."
    }
    $token = [string](@(& $GetAccessToken) | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($token)) { throw "Power Automate sign-in returned an empty access token." }
    return @{ Authorization = "Bearer $token" }
}

function Send-RefreshEmail {
    # Returns SignedIn = $true when the call carried a Power Automate token.
    param(
        [Parameter(Mandatory = $true)][string]$WebhookUrl,
        [Parameter(Mandatory = $true)][string[]]$Recipients,
        [Parameter(Mandatory = $true)][string]$Subject,
        [Parameter(Mandatory = $true)][string]$HtmlBody,
        # Returns a Power Automate access token. Called only when the flow needs one.
        [AllowNull()][scriptblock]$GetAccessToken
    )

    $payload = [ordered]@{
        recipients = @($Recipients)
        subject = $Subject
        htmlBody = $HtmlBody
    } | ConvertTo-Json -Depth 5
    $body = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $post = {
        param([string]$Url, [hashtable]$Headers)
        Invoke-RestMethod -Method POST -Uri $Url -Headers $Headers -ContentType "application/json; charset=utf-8" -Body $body -TimeoutSec 60 -ErrorAction Stop | Out-Null
    }
    $postSignedIn = {
        $headers = Get-RefreshFlowAuthorizationHeader -WebhookUrl $WebhookUrl -GetAccessToken $GetAccessToken
        try {
            & $post (Get-RefreshFlowUrlWithoutKey $WebhookUrl) $headers
        } catch {
            $status = Get-RefreshFlowHttpStatus $_
            if ($status -eq 401 -or $status -eq 403) {
                throw "The flow refused the signed-in call (HTTP $status). Check the trigger's 'Who can trigger the flow?' setting: with 'Specific users in my tenant', the account or app that signs in here must be listed."
            }
            throw
        }
    }

    if (-not (Test-RefreshFlowUrlHasKey $WebhookUrl)) {
        & $postSignedIn
        return [pscustomobject]@{ SignedIn = $true }
    }
    try {
        & $post $WebhookUrl @{}
        return [pscustomobject]@{ SignedIn = $false }
    } catch {
        $status = Get-RefreshFlowHttpStatus $_
        if (($status -ne 401 -and $status -ne 403) -or $null -eq $GetAccessToken) { throw }
    }
    & $postSignedIn
    return [pscustomobject]@{ SignedIn = $true }
}
