# ============================================================
# Step 3 - Deploy the AKS Store demo application
# ============================================================
$ErrorActionPreference = "Stop"
$appManifestsDir = Join-Path $PSScriptRoot "manifests\aks-store"

# Create the namespace
kubectl create ns pets --dry-run=client -o yaml | kubectl apply -f -

# Deploy the pet store from the local manifests folder
kubectl apply -f $appManifestsDir -n pets

Write-Host "Waiting for all pods to be Ready..." -ForegroundColor Yellow
kubectl wait --for=condition=Ready pod --all -n pets --timeout=300s

# Check deployment status
kubectl get all -n pets

# Print the internal service address and local access command
$storeIp = kubectl get svc store-front -n pets -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
Write-Host ""
Write-Host "Internal Store Front address: http://$storeIp" -ForegroundColor Cyan
Write-Host "To open it from this Bastion shell, run:" -ForegroundColor Cyan
Write-Host "  kubectl port-forward -n pets service/store-front 8080:80" -ForegroundColor White
Write-Host "Then browse to http://localhost:8080 on this workstation." -ForegroundColor Cyan
