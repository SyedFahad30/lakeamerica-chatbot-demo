<#
.SYNOPSIS
  Points chat-widget.js at your live API Gateway endpoint after deploy.ps1
  prints it out.

.USAGE
  .\update-widget-endpoint.ps1 -Endpoint "https://xxxxx.execute-api.us-east-1.amazonaws.com/"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Endpoint
)

$File = ".\chat-widget.js"

if (-not (Test-Path $File)) {
    Write-Host "$File not found in this directory." -ForegroundColor Red
    exit 1
}

Copy-Item $File "$File.bak"

$content = Get-Content $File -Raw
$updated = $content -replace 'apiEndpoint:\s*"[^"]*",', "apiEndpoint: `"$Endpoint`","
Set-Content -Path $File -Value $updated -NoNewline

Write-Host "Updated $File to call: $Endpoint"
Write-Host "(backup saved as $File.bak)"
