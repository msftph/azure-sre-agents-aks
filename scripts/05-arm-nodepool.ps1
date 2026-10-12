# ============================================================
# Step 5 - Apply the ARM64 NodePool profile
#   Prioritises ARM-based D-family VMs via NAP/Karpenter
# ============================================================
$ErrorActionPreference = "Stop"
$manifestsDir = Join-Path $PSScriptRoot "..\manifests"

kubectl apply -f (Join-Path $manifestsDir "arm-nodepool-profile.yaml")

Write-Host "ARM NodePool profile applied." -ForegroundColor Green
Write-Host ""
Write-Host "--- Monitor with ---" -ForegroundColor Cyan
Write-Host "  kubectl get events -A --field-selector source=karpenter -w"
Write-Host "  kubectl get nodes,pods -n pets -o wide -w"
