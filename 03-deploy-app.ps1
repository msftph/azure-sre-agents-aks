# ============================================================
# Step 3 - Deploy the AKS Store demo application
# ============================================================
$ErrorActionPreference = "Stop"
$appManifestsDir = Join-Path $PSScriptRoot "manifests\aks-store"

# Create the namespace
kubectl create ns pets --dry-run=client -o yaml | kubectl apply -f -

# Files with a "-changed" suffix intentionally reproduce incident conditions.
# Deploy only the healthy baseline during environment setup.
$baselineManifests = Get-ChildItem `
  -Path $appManifestsDir `
  -Filter "*.yaml" `
  -File |
  Where-Object { $_.BaseName -notlike "*-changed" } |
  Sort-Object Name

foreach ($manifest in $baselineManifests) {
    kubectl apply -f $manifest.FullName -n pets
    if ($LASTEXITCODE -ne 0) {
        throw "Applying '$($manifest.Name)' failed with exit code $LASTEXITCODE."
    }
}

Write-Host "Waiting for workloads to finish rolling out..." -ForegroundColor Yellow
$workloads = kubectl get deployments,statefulsets -n pets -o name
if ($LASTEXITCODE -ne 0) {
    throw "Listing pets namespace workloads failed with exit code $LASTEXITCODE."
}

foreach ($workload in $workloads) {
    kubectl rollout status $workload -n pets --timeout=300s
    if ($LASTEXITCODE -ne 0) {
        throw "Rollout for '$workload' did not complete within 300 seconds."
    }
}

# Check deployment status
kubectl get all -n pets

# Print the internal service address and local access command
$loadBalancerDeadline = (Get-Date).AddMinutes(5)
do {
    $storeIp = kubectl get svc store-front -n pets -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
    $adminIp = kubectl get svc store-admin -n pets -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

    if (
        [string]::IsNullOrWhiteSpace($storeIp) -or
        [string]::IsNullOrWhiteSpace($adminIp)
    ) {
        Start-Sleep -Seconds 10
    }
} while (
    (
        [string]::IsNullOrWhiteSpace($storeIp) -or
        [string]::IsNullOrWhiteSpace($adminIp)
    ) -and
    (Get-Date) -lt $loadBalancerDeadline
)

if (
    [string]::IsNullOrWhiteSpace($storeIp) -or
    [string]::IsNullOrWhiteSpace($adminIp)
) {
    throw "The internal load balancers did not receive addresses within 5 minutes."
}

if (-not $storeIp.StartsWith("10.224.") -or -not $adminIp.StartsWith("10.224.")) {
    throw "Expected private load balancer addresses in 10.224.0.0/16, received Store Front '$storeIp' and Store Admin '$adminIp'."
}

Write-Host ""
Write-Host "Internal Store Front address: http://$storeIp" -ForegroundColor Cyan
Write-Host "Internal Store Admin address: http://$adminIp" -ForegroundColor Cyan
Write-Host "To open it from this Bastion shell, run:" -ForegroundColor Cyan
Write-Host "  kubectl port-forward -n pets service/store-front 8080:80" -ForegroundColor White
Write-Host "Then browse to http://localhost:8080 on this workstation." -ForegroundColor Cyan
