# Sends one email through the Power Automate webhook (REFRESH_EMAIL_WEBHOOK_URL).
# The email itself is built by New-ValidationEmailContent in validation\validation.ps1:
# every refresh, from the Control Panel, the Claude skill or the validated refresh, sends
# that one format (the refresh table and the before/after checks of each semantic model).

function Send-RefreshEmail {
    param(
        [Parameter(Mandatory = $true)][string]$WebhookUrl,
        [Parameter(Mandatory = $true)][string[]]$Recipients,
        [Parameter(Mandatory = $true)][string]$Subject,
        [Parameter(Mandatory = $true)][string]$HtmlBody
    )

    $payload = [ordered]@{
        recipients = @($Recipients)
        subject = $Subject
        htmlBody = $HtmlBody
    } | ConvertTo-Json -Depth 5

    Invoke-RestMethod -Method POST -Uri $WebhookUrl -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec 60 -ErrorAction Stop | Out-Null
}
