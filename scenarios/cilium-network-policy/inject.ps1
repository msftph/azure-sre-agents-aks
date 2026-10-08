$ErrorActionPreference = "Stop"
$badPoliciesDir = Join-Path $PSScriptRoot "manifests\bad"

kubectl apply -f (Join-Path $badPoliciesDir "01-cross-namespace.yaml")
if ($LASTEXITCODE -ne 0) {
    throw "Failed to apply the cross-namespace misconfiguration."
}

kubectl apply -f (Join-Path $badPoliciesDir "02-cidr.yaml")
if ($LASTEXITCODE -ne 0) {
    throw "Failed to apply the CIDR misconfiguration."
}

kubectl delete ciliumnetworkpolicy service-port-egress `
    -n cilium-policy-demo `
    --ignore-not-found
if ($LASTEXITCODE -ne 0) {
    throw "Failed to remove the existing service/port policy before fault injection."
}

kubectl apply -f (Join-Path $badPoliciesDir "03-service-port.yaml")
if ($LASTEXITCODE -ne 0) {
    Write-Warning "The API rejected the unsupported toServices/toPorts policy. This is an expected failure mode."
}
else {
    Write-Warning "The unsupported toServices/toPorts policy object was accepted. Inspect its Cilium status and agent logs."
}

Start-Sleep -Seconds 5
Write-Host ""
Write-Host "Misconfigurations injected." -ForegroundColor Yellow
Write-Host "Run: .\test.ps1 -ExpectedState Broken" -ForegroundColor Cyan
