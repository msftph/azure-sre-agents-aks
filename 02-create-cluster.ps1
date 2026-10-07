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

Write-Host "Deploying private AKS networking and Azure Bastion..." -ForegroundColor Yellow
$prerequisiteOutputs = az deployment group create `
  --name "private-aks-prerequisites" `
  --resource-group $RESOURCE_GROUP `
  --template-file "$PSScriptRoot\infra\private-cluster-prereqs.bicep" `
  --parameters "$PSScriptRoot\infra\private-cluster-prereqs.bicepparam" `
  --parameters location=$LOCATION `
  --query "properties.outputs" `
  --output json | ConvertFrom-Json
Assert-AzCliSucceeded "Deploying private AKS prerequisites"

$aksNodeSubnetId = $prerequisiteOutputs.aksNodeSubnetId.value
$aksApiServerSubnetId = $prerequisiteOutputs.aksApiServerSubnetId.value
$aksIdentityId = $prerequisiteOutputs.aksIdentityId.value
$managementVirtualNetworkId = $prerequisiteOutputs.managementVirtualNetworkId.value
$bastionId = $prerequisiteOutputs.bastionId.value

# Create AKS cluster (this takes several minutes)
Write-Host "Creating private AKS cluster '$CLUSTER_NAME'... this takes several minutes." -ForegroundColor Yellow
az aks create `
  --name $CLUSTER_NAME `
  --resource-group $RESOURCE_GROUP `
  --enable-managed-identity `
  --assign-identity $aksIdentityId `
  --vnet-subnet-id $aksNodeSubnetId `
  --enable-apiserver-vnet-integration `
  --apiserver-subnet-id $aksApiServerSubnetId `
  --enable-private-cluster `
  --disable-public-fqdn `
  --private-dns-zone system `
  --node-provisioning-mode Auto `
  --network-plugin azure `
  --network-plugin-mode overlay `
  --network-dataplane cilium `
  --pod-cidr 10.244.0.0/16 `
  --service-cidr 10.0.0.0/16 `
  --dns-service-ip 10.0.0.10 `
  --enable-azure-monitor-metrics `
  --generate-ssh-keys
Assert-AzCliSucceeded "Creating private AKS cluster '$CLUSTER_NAME'"

$nodeResourceGroup = az aks show `
  --resource-group $RESOURCE_GROUP `
  --name $CLUSTER_NAME `
  --query nodeResourceGroup `
  --output tsv
Assert-AzCliSucceeded "Reading the AKS node resource group"

$privateDnsZones = az network private-dns zone list `
  --resource-group $nodeResourceGroup `
  --output json | ConvertFrom-Json
Assert-AzCliSucceeded "Listing AKS private DNS zones"

$privateDnsZone = $privateDnsZones |
  Where-Object { $_.name -like "*.privatelink.$LOCATION.azmk8s.io" } |
  Select-Object -First 1

if ($null -eq $privateDnsZone) {
    throw "The AKS-managed private DNS zone was not found in '$nodeResourceGroup'."
}

az network private-dns link vnet create `
  --resource-group $nodeResourceGroup `
  --zone-name $privateDnsZone.name `
  --name "link-vnet-sre-agent-aks-demo" `
  --virtual-network $managementVirtualNetworkId `
  --registration-enabled false `
  --only-show-errors
Assert-AzCliSucceeded "Linking the AKS private DNS zone to the management VNet"

Write-Host "Private cluster and Azure Bastion are ready." -ForegroundColor Green
Write-Host "Bastion resource: $bastionId" -ForegroundColor Cyan
Write-Host "Run .\Connect-AksViaBastion.ps1 to open a kubectl-enabled subshell." -ForegroundColor Cyan
