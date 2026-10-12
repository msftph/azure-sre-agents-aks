# ============================================================
# Step 6 - Apply the ARM64 NodePool v2 (with Azure Linux NodeClass)
#   Adds a custom AKSNodeClass for Azure Linux + updates the NodePool
# ============================================================
$ErrorActionPreference = "Stop"
$manifestsDir = Join-Path $PSScriptRoot "..\manifests"

kubectl apply -f (Join-Path $manifestsDir "arm-nodepool-profile-v2.yaml")

Write-Host "ARM NodePool v2 (Azure Linux) applied." -ForegroundColor Green
Write-Host ""
Write-Host "--- Monitor with ---" -ForegroundColor Cyan
Write-Host "  kubectl get events -A --field-selector source=karpenter -w"
Write-Host "  kubectl get nodes,pods -n pets -o wide -w"
