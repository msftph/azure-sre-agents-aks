# ============================================================
# Step 3 - Deploy the AKS Store demo application
# ============================================================
$ErrorActionPreference = "Stop"
$appManifestsDir = Join-Path $PSScriptRoot "manifests\aks-store"

function Assert-KubectlSucceeded {
    param([Parameter(Mandatory)][string]$Operation)

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with kubectl exit code $LASTEXITCODE."
    }
}

# Create the namespace
kubectl create ns pets --dry-run=client -o yaml | kubectl apply -f -
Assert-KubectlSucceeded "Creating the pets namespace"

# Apply only the numbered baseline manifests. Other files in this directory
# intentionally reproduce incidents and must not be part of initial deployment.
$baselineManifests = Get-ChildItem `
  -Path $appManifestsDir `
  -Filter "*.yaml" |
  Where-Object Name -Match '^\d{2}-' |
  Sort-Object Name

foreach ($manifest in $baselineManifests) {
    kubectl apply -f $manifest.FullName -n pets
    Assert-KubectlSucceeded "Applying $($manifest.Name)"
}

Write-Host "Waiting for all pods to be Ready..." -ForegroundColor Yellow
$deployments = kubectl get deployment -n pets -o name
Assert-KubectlSucceeded "Listing pets deployments"
foreach ($deployment in $deployments) {
    kubectl rollout status $deployment -n pets --timeout=300s
    Assert-KubectlSucceeded "Waiting for $deployment to complete"
}

$statefulSets = kubectl get statefulset -n pets -o name
Assert-KubectlSucceeded "Listing pets stateful sets"
foreach ($statefulSet in $statefulSets) {
    kubectl rollout status $statefulSet -n pets --timeout=300s
    Assert-KubectlSucceeded "Waiting for $statefulSet to complete"
}

kubectl wait --for=condition=Ready pod --all -n pets --timeout=300s
Assert-KubectlSucceeded "Waiting for pets pods to become Ready"

# Check deployment status
kubectl get all -n pets
Assert-KubectlSucceeded "Reading pets workload status"

# Print the store URL
$storeIpDeadline = (Get-Date).AddMinutes(5)
do {
    $storeIp = kubectl get svc store-front `
      -n pets `
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
    Assert-KubectlSucceeded "Reading the Store Front public IP"

    if (-not $storeIp) {
        Start-Sleep -Seconds 10
    }
} while (-not $storeIp -and (Get-Date) -lt $storeIpDeadline)

if (-not $storeIp) {
    throw "Store Front did not receive a public IP within 5 minutes."
}

Write-Host ""
Write-Host "Pet Store URL: http://$storeIp" -ForegroundColor Cyan
