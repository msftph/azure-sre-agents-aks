# ============================================================
# Step 2 - Create the AKS cluster
#   NAP enabled, Azure CNI Overlay with Cilium
# ============================================================
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\00-variables.ps1"

function Assert-AzCliSucceeded {
    param([Parameter(Mandatory)][string]$Operation)

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with Azure CLI exit code $LASTEXITCODE."
    }
}

# Create resource group
az group create -n $RESOURCE_GROUP -l $LOCATION
Assert-AzCliSucceeded "Creating resource group '$RESOURCE_GROUP'"

# Create AKS cluster (this takes several minutes)
Write-Host "Creating AKS cluster '$CLUSTER_NAME'... this takes several minutes." -ForegroundColor Yellow
az aks create `
  --name $CLUSTER_NAME `
  --resource-group $RESOURCE_GROUP `
  --kubernetes-version $KUBERNETES_VERSION `
  --node-count $NODE_COUNT `
  --node-vm-size $NODE_VM_SIZE `
  --node-provisioning-mode Auto `
  --network-plugin azure `
  --network-plugin-mode overlay `
  --network-dataplane cilium `
  --enable-azure-monitor-metrics `
  --yes `
  --generate-ssh-keys
Assert-AzCliSucceeded "Creating AKS cluster '$CLUSTER_NAME'"

# Get cluster credentials
az aks get-credentials -g $RESOURCE_GROUP -n $CLUSTER_NAME
Assert-AzCliSucceeded "Getting credentials for AKS cluster '$CLUSTER_NAME'"

Write-Host "Cluster created and kubeconfig configured." -ForegroundColor Green
