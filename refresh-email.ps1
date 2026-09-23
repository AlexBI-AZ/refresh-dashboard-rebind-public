function ConvertTo-RefreshHtml {
    param([AllowNull()][object]$Value)

    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-RefreshEmailContent {
    param(
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)][datetime]$StartTime,
        [Parameter(Mandatory = $true)][datetime]$EndTime
    )

    $successStatuses = @("Success", "Succeeded", "Completed")
    $hasErrors = @($Items | Where-Object { $successStatuses -notcontains [string]$_.Status }).Count -gt 0
    $subject = if ($hasErrors) {
        "$([char]0x26A0) Refresh completed with errors"
    } else {
        "$([char]0x2705) Refresh completed: $($Items.Count) items"
    }

    $rows = foreach ($item in $Items) {
        $status = [string]$item.Status
        $statusColor = if ($successStatuses -contains $status) { "#15803d" } elseif ($status -eq "Skipped") { "#a16207" } else { "#b91c1c" }
        $errorText = if ([string]::IsNullOrWhiteSpace([string]$item.Error)) { "&mdash;" } else { ConvertTo-RefreshHtml $item.Error }
        "<tr>" +
            "<td>$(ConvertTo-RefreshHtml $item.Type)</td>" +
            "<td>$(ConvertTo-RefreshHtml $item.Name)</td>" +
            "<td>$(ConvertTo-RefreshHtml $item.WorkspaceName)</td>" +
            "<td style=`"font-weight:600;color:$statusColor`">$(ConvertTo-RefreshHtml $status)</td>" +
            "<td>$errorText</td>" +
        "</tr>"
    }

    $duration = $EndTime - $StartTime
    $durationText = if ($duration.TotalHours -ge 1) {
        "{0:00}:{1:00}:{2:00}" -f [math]::Floor($duration.TotalHours), $duration.Minutes, $duration.Seconds
    } else {
        "{0:00}:{1:00}" -f [math]::Floor($duration.TotalMinutes), $duration.Seconds
    }

    $htmlBody = @"
<!doctype html>
<html>
<body style="font-family:Segoe UI,Arial,sans-serif;color:#1f2937;margin:0;padding:24px;background:#f3f4f6;">
  <div style="max-width:900px;margin:0 auto;background:#ffffff;border:1px solid #e5e7eb;border-radius:10px;overflow:hidden;">
    <div style="padding:20px 24px;background:#111827;color:#ffffff;">
      <h2 style="margin:0;font-size:20px;">$(ConvertTo-RefreshHtml $subject)</h2>
    </div>
    <div style="padding:20px 24px;">
      <p style="margin:0 0 16px;line-height:1.5;">
        <strong>Started:</strong> $(ConvertTo-RefreshHtml $StartTime.ToString("yyyy-MM-dd HH:mm:ss zzz"))<br>
        <strong>Finished:</strong> $(ConvertTo-RefreshHtml $EndTime.ToString("yyyy-MM-dd HH:mm:ss zzz"))<br>
        <strong>Duration:</strong> $(ConvertTo-RefreshHtml $durationText)
      </p>
      <table style="width:100%;border-collapse:collapse;font-size:13px;">
        <thead>
          <tr style="background:#f9fafb;text-align:left;">
            <th style="padding:9px;border:1px solid #e5e7eb;">Type</th>
            <th style="padding:9px;border:1px solid #e5e7eb;">Item</th>
            <th style="padding:9px;border:1px solid #e5e7eb;">Workspace</th>
            <th style="padding:9px;border:1px solid #e5e7eb;">Status</th>
            <th style="padding:9px;border:1px solid #e5e7eb;">Error</th>
          </tr>
        </thead>
        <tbody>
          $($rows -join [Environment]::NewLine)
        </tbody>
      </table>
    </div>
  </div>
</body>
</html>
"@

    return [pscustomobject]@{
        Subject = $subject
        HtmlBody = $htmlBody
        HasErrors = $hasErrors
    }
}

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
