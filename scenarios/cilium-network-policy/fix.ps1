$ErrorActionPreference = "Stop"
$goodPoliciesDir = Join-Path $PSScriptRoot "manifests\good"

kubectl apply -f $goodPoliciesDir
if ($LASTEXITCODE -ne 0) {
    throw "Failed to apply the corrected Cilium policies."
}

Start-Sleep -Seconds 5
Write-Host ""
Write-Host "Corrected policies applied." -ForegroundColor Green
Write-Host "Run: .\test.ps1 -ExpectedState Fixed" -ForegroundColor Cyan
