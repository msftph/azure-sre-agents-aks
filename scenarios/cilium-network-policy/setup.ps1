$ErrorActionPreference = "Stop"
$manifestsDir = Join-Path $PSScriptRoot "manifests"

if (-not (kubectl get crd ciliumnetworkpolicies.cilium.io --ignore-not-found -o name)) {
    throw "CiliumNetworkPolicy CRD was not found. Use an AKS cluster with Azure CNI powered by Cilium."
}

kubectl apply -f (Join-Path $manifestsDir "00-base.yaml")
if ($LASTEXITCODE -ne 0) {
    throw "Failed to deploy the scenario workloads."
}

kubectl wait --for=condition=Available deployment --all -n cilium-policy-demo --timeout=300s
if ($LASTEXITCODE -ne 0) {
    throw "Waiting for deployments in 'cilium-policy-demo' to become available failed with exit code $LASTEXITCODE."
}

kubectl wait --for=condition=Available deployment --all -n cilium-policy-observer --timeout=300s
if ($LASTEXITCODE -ne 0) {
    throw "Waiting for deployments in 'cilium-policy-observer' to become available failed with exit code $LASTEXITCODE."
}

$networkLogCrd = kubectl get crd containernetworklogs.acn.azure.com --ignore-not-found -o name
if ($networkLogCrd) {
    kubectl apply -f (Join-Path $manifestsDir "observability.yaml")
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Workloads are ready, but the optional ACNS flow-log filter could not be applied."
    }
}
else {
    Write-Warning "ACNS ContainerNetworkLog CRD was not found. The lab will use live Cilium diagnostics only."
}

Write-Host ""
Write-Host "Scenario workloads are ready." -ForegroundColor Green
Write-Host "Next: .\inject.ps1" -ForegroundColor Cyan
