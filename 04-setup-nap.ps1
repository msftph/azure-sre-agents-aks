# ============================================================
# Step 4 - Verify the Bicep-managed system taint and monitor NAP
# ============================================================
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\00-variables.ps1"

# Inspect the Bicep-managed system node pool
$systemNodepool = az aks nodepool list `
  -g $RESOURCE_GROUP `
  --cluster-name $CLUSTER_NAME `
  --query "[?mode=='System'] | [0]" -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw "Reading the system node pool failed with Azure CLI exit code $LASTEXITCODE."
}

if ($null -eq $systemNodepool -or $systemNodepool.nodeTaints -notcontains "CriticalAddonsOnly=true:NoExecute") {
    throw "The system pool is missing its Bicep-managed taint. Deploy the private cluster with .\02-create-cluster.ps1 first."
}
Write-Host "System nodepool: $($systemNodepool.name)" -ForegroundColor Yellow

Write-Host ""
Write-Host "System taint verified. NAP provisions user-mode nodes for app pods from Step 3." -ForegroundColor Green
Write-Host ""
Write-Host "--- Monitor with ---" -ForegroundColor Cyan
Write-Host "  kubectl get events -A --field-selector source=karpenter -w"
Write-Host "  kubectl get nodes,pods -n pets -o wide -w"
Write-Host ""
Write-Host "--- Inspect existing NAP nodepools ---" -ForegroundColor Cyan
Write-Host "  kubectl get nodepool"
Write-Host "  kubectl describe nodepool default"
Write-Host "  kubectl describe nodepool system-surge"
