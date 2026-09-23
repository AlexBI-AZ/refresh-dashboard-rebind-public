param(
    [string]$PowerBiScope = "https://analysis.windows.net/powerbi/api/.default",
    [string]$FabricScope  = "https://api.fabric.microsoft.com/.default"
)

$ClientId = "1950a258-227b-4e31-a9cf-717495945fc2"
$scopes = @($PowerBiScope, $FabricScope)

Write-Host "This script pre-authenticates for Power BI and Fabric APIs." -ForegroundColor Cyan
Write-Host "Run it once. After that, refresh-dataflow-then-dataset.ps1 runs silently." -ForegroundColor Cyan
Write-Host ""

foreach ($scope in $scopes) {
    try {
        $token = Get-MsalToken -ClientId $ClientId -TenantId "common" -Scopes $scope -Silent -ErrorAction Stop
        Write-Host "Already authenticated for: $scope" -ForegroundColor Green
    }
    catch {
        Write-Host "Need to authenticate for: $scope" -ForegroundColor Yellow
        Get-MsalToken -ClientId $ClientId -TenantId "common" -Scopes $scope -DeviceCode | Out-Null
        Write-Host "Done." -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "All tokens cached. You can now run refresh-dataflow-then-dataset.ps1 without any prompts." -ForegroundColor Cyan
