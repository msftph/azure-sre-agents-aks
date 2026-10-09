# ============================================================
# Step 2 - Create the AKS cluster
#   NAP enabled, Azure CNI Overlay with Cilium
# ============================================================
param(
    [string]$SshPublicKeyPath = "$HOME/.ssh/id_rsa.pub",
    [switch]$EnableContainerNetworkLogs
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\00-variables.ps1"

function Assert-AzCliSucceeded {
    param([Parameter(Mandatory)][string]$Operation)

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with Azure CLI exit code $LASTEXITCODE."
    }
}

# Deploy resource group
az deployment sub create `
  --name "sre-agent-resource-group" `
  --location $LOCATION `
  --template-file "$PSScriptRoot\infra\resource-group.bicep" `
  --parameters resourceGroupName=$RESOURCE_GROUP location=$LOCATION `
  --only-show-errors
Assert-AzCliSucceeded "Deploying resource group '$RESOURCE_GROUP'"

if (-not (Test-Path $SshPublicKeyPath)) {
    if (-not $SshPublicKeyPath.EndsWith(".pub")) {
        throw "The SSH public key path must end in '.pub'."
    }
    $privateKeyPath = $SshPublicKeyPath.Substring(0, $SshPublicKeyPath.Length - 4)
    if (Test-Path $privateKeyPath) {
        throw "Private key '$privateKeyPath' exists but its public key is missing. Restore the public key rather than overwriting the private key."
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $SshPublicKeyPath -Parent) | Out-Null
    ssh-keygen -t rsa -b 4096 -f $privateKeyPath -N "" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Generating the local SSH key failed with exit code $LASTEXITCODE."
    }
}
$sshPublicKey = (Get-Content -Raw $SshPublicKeyPath).Trim()
if ($sshPublicKey -notmatch '^ssh-(rsa|ed25519)\s+\S+') {
    throw "'$SshPublicKeyPath' must contain an SSH public key, not a private key."
}

$policyManagedNsgNames = @(
    "vnet-sre-agent-aks-demo-snet-sre-agent-nsg-$LOCATION"
    "vnet-sre-agent-aks-demo-AzureBastionSubnet-nsg-$LOCATION"
    "vnet-aks-sre-agent-demo-snet-aks-nodes-nsg-$LOCATION"
    "vnet-aks-sre-agent-demo-snet-aks-api-server-nsg-$LOCATION"
)
$existingPolicyManagedNsgCount = 0
foreach ($networkSecurityGroupName in $policyManagedNsgNames) {
    az network nsg show `
      --resource-group $RESOURCE_GROUP `
      --name $networkSecurityGroupName `
      --only-show-errors `
      --output none 2>$null

    if ($LASTEXITCODE -eq 0) {
        $existingPolicyManagedNsgCount++
    }
}

if ($existingPolicyManagedNsgCount -eq $policyManagedNsgNames.Count) {
    $associateExistingPolicyManagedNsgs = "true"
} elseif ($existingPolicyManagedNsgCount -eq 0) {
    $associateExistingPolicyManagedNsgs = "false"
} else {
    throw "Only $existingPolicyManagedNsgCount of $($policyManagedNsgNames.Count) expected policy-managed NSGs exist. Resolve the partial policy deployment before updating the VNets."
}

Write-Host "Deploying private AKS, networking, telemetry, and Azure Bastion... this takes several minutes." -ForegroundColor Yellow
$previousSshPublicKey = $env:AKS_SSH_PUBLIC_KEY
try {
    $env:AKS_SSH_PUBLIC_KEY = $sshPublicKey
    $prerequisiteOutputs = az deployment group create `
      --name "private-aks-prerequisites" `
      --resource-group $RESOURCE_GROUP `
      --template-file "$PSScriptRoot\infra\private-cluster-prereqs.bicep" `
      --parameters "$PSScriptRoot\infra\private-cluster-prereqs.bicepparam" `
      --parameters location=$LOCATION aksClusterName=$CLUSTER_NAME associateExistingPolicyManagedNsgs=$associateExistingPolicyManagedNsgs `
      enableContainerNetworkLogs=$($EnableContainerNetworkLogs.IsPresent.ToString().ToLowerInvariant()) `
      --query "properties.outputs" `
      --output json | ConvertFrom-Json
    Assert-AzCliSucceeded "Deploying private AKS and prerequisites"
} finally {
    $env:AKS_SSH_PUBLIC_KEY = $previousSshPublicKey
}

$managementVirtualNetworkId = $prerequisiteOutputs.managementVirtualNetworkId.value
$bastionId = $prerequisiteOutputs.bastionId.value
$nodeResourceGroup = $prerequisiteOutputs.nodeResourceGroup.value

$privateDnsZones = az network private-dns zone list `
  --resource-group $nodeResourceGroup `
  --output json | ConvertFrom-Json
Assert-AzCliSucceeded "Listing AKS private DNS zones"

$privateDnsZone = $privateDnsZones |
  Where-Object {
      $_.name -like "*.private.$LOCATION.azmk8s.io" -or
      $_.name -like "*.privatelink.$LOCATION.azmk8s.io"
  } |
  Select-Object -First 1

if ($null -eq $privateDnsZone) {
    throw "The AKS-managed private DNS zone was not found in '$nodeResourceGroup'."
}

az deployment group create `
  --name "private-aks-management-dns-link" `
  --resource-group $nodeResourceGroup `
  --template-file "$PSScriptRoot\infra\modules\private-dns-link.bicep" `
  --parameters privateDnsZoneName=$($privateDnsZone.name) managementVirtualNetworkId=$managementVirtualNetworkId `
  --only-show-errors
Assert-AzCliSucceeded "Linking the AKS private DNS zone to the management VNet"

$azureMonitorWorkspaceId = $prerequisiteOutputs.azureMonitorWorkspaceId.value
$recommendations = az rest `
  --method get `
  --url "$azureMonitorWorkspaceId/providers/Microsoft.AlertsManagement/alertRuleRecommendations?api-version=2023-01-01-preview" `
  --output json | ConvertFrom-Json
Assert-AzCliSucceeded "Reading Azure Monitor recording-rule recommendations"

$ruleGroups = @(
    foreach ($recommendation in $recommendations.value) {
        if ($recommendation.properties.alertRuleType -ne "Microsoft.AlertsManagement/prometheusRuleGroups") {
            continue
        }
        foreach ($resource in $recommendation.properties.rulesArmTemplate.resources) {
            if ($resource.type -ne "Microsoft.AlertsManagement/prometheusRuleGroups") {
                continue
            }
            $rules = @($resource.properties.rules)
            $alertRules = @($rules | Where-Object { -not $_.record -or -not $_.expression })
            if ($rules.Count -gt 0 -and $alertRules.Count -eq 0) {
                @{
                    name = $recommendation.name
                    rules = $rules
                }
            }
        }
    }
)

if ($ruleGroups.Count -gt 0) {
    $recordingRuleParameters = New-TemporaryFile
    try {
        @{
            parameters = @{
                ruleGroups = @{ value = $ruleGroups }
            }
        } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $recordingRuleParameters.FullName

        az deployment group create `
          --name "private-aks-recording-rules" `
          --resource-group $RESOURCE_GROUP `
          --template-file "$PSScriptRoot\infra\modules\prometheus-recording-rules.bicep" `
          --parameters "@$($recordingRuleParameters.FullName)" `
          --parameters location=$LOCATION aksClusterName=$CLUSTER_NAME `
          aksClusterId=$($prerequisiteOutputs.aksClusterId.value) azureMonitorWorkspaceId=$azureMonitorWorkspaceId `
          --only-show-errors
        Assert-AzCliSucceeded "Deploying Azure Monitor recording rules"
    } finally {
        Remove-Item -LiteralPath $recordingRuleParameters.FullName -Force
    }
} else {
    Write-Warning "Azure Monitor returned no recording-rule recommendations. Metrics ingestion is enabled; rerun Step 2 to retry recommendation discovery."
}

Write-Host "Private cluster and Azure Bastion are ready." -ForegroundColor Green
Write-Host "Bastion resource: $bastionId" -ForegroundColor Cyan
Write-Host "Run .\Connect-AksViaBastion.ps1 to open a kubectl-enabled subshell." -ForegroundColor Cyan
