targetScope = 'subscription'

@description('Name of the resource group for the complete demo infrastructure.')
param resourceGroupName string

@description('Azure region for the demo infrastructure.')
param location string

@description('Name of the private AKS cluster the SRE Agent manages.')
param aksClusterName string

@description('SSH public key for the Linux nodes. Never supply a private key.')
@minLength(1)
param sshPublicKey string

@description('VM size for the system node pool.')
param systemNodeVmSize string = 'Standard_D4s_v5'

@minValue(1)
@description('Number of nodes in the system node pool.')
param systemNodeCount int = 3

@description('Name of the Azure Monitor workspace for managed Prometheus.')
param azureMonitorWorkspaceName string = 'amw-sre-agent-aks-demo'

@description('Forward ACNS container network logs to Container Insights.')
param enableContainerNetworkLogs bool = false

@description('Name of the Azure SRE Agent resource.')
param sreAgentName string = 'sre-agent-aks-demo'

@description('Name of the user-assigned managed identity used by the SRE Agent.')
param managedIdentityName string = 'id-sre-agent-aks-demo'

@description('Name of the Log Analytics workspace used by the SRE Agent.')
param logAnalyticsWorkspaceName string = 'law-sre-agent-aks-demo'

@description('Name of the Application Insights component used by the SRE Agent.')
param applicationInsightsName string = 'appi-sre-agent-aks-demo'

@description('Name of the management virtual network used by SRE Agent and Bastion.')
param managementVirtualNetworkName string = 'vnet-sre-agent-aks-demo'

@description('Address space for the management virtual network.')
param managementVirtualNetworkAddressPrefix string = '10.250.0.0/24'

@description('Name of the delegated SRE Agent subnet.')
param agentSubnetName string = 'snet-sre-agent'

@description('Address prefix for the delegated SRE Agent subnet. Azure SRE Agent requires at least a /27.')
param agentSubnetAddressPrefix string = '10.250.0.0/27'

@description('Address prefix for AzureBastionSubnet. Azure Bastion requires at least a /26.')
param bastionSubnetAddressPrefix string = '10.250.0.64/26'

@description('Name of the customer-managed AKS virtual network.')
param aksVirtualNetworkName string = 'vnet-aks-sre-agent-demo'

@description('Address space for the customer-managed AKS virtual network.')
param aksVirtualNetworkAddressPrefix string = '10.224.0.0/16'

@description('Name of the AKS node subnet.')
param aksNodeSubnetName string = 'snet-aks-nodes'

@description('Address prefix for the AKS node subnet.')
param aksNodeSubnetAddressPrefix string = '10.224.0.0/20'

@description('Name of the AKS API server subnet.')
param aksApiServerSubnetName string = 'snet-aks-api-server'

@description('Address prefix for the AKS API server subnet.')
param aksApiServerSubnetAddressPrefix string = '10.224.16.0/28'

@description('Preserve policy-managed NSG associations when updating existing subnets.')
param associateExistingPolicyManagedNsgs bool = false

@description('Name of the AKS user-assigned managed identity.')
param aksIdentityName string = 'id-aks-sre-agent-demo'

@description('Name of the Azure Bastion resource.')
param bastionName string = 'bas-sre-agent-aks-demo'

@description('Name of the Standard public IP address used by Azure Bastion.')
param bastionPublicIpName string = 'pip-bas-sre-agent-aks-demo'

@minValue(2)
@maxValue(50)
@description('Number of Azure Bastion scale units.')
param bastionScaleUnits int = 2

@description('Create the role assignments required by the demo. Set false when equivalent assignments already exist.')
param deployRoleAssignments bool = true

var nodeResourceGroupName = 'MC_${resourceGroupName}_${aksClusterName}_${location}'

resource publicIpFeature 'Microsoft.Features/featureProviders/subscriptionFeatureRegistrations@2021-07-01' = {
  name: 'Microsoft.Network/AllowBringYourOwnPublicIpAddress'
  properties: {}
}

resource demoResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

module network './modules/network.bicep' = {
  name: 'private-aks-network'
  scope: resourceGroup(demoResourceGroup.name)
  params: {
    location: location
    managementVirtualNetworkName: managementVirtualNetworkName
    managementVirtualNetworkAddressPrefix: managementVirtualNetworkAddressPrefix
    agentSubnetName: agentSubnetName
    agentSubnetAddressPrefix: agentSubnetAddressPrefix
    bastionSubnetAddressPrefix: bastionSubnetAddressPrefix
    aksVirtualNetworkName: aksVirtualNetworkName
    aksVirtualNetworkAddressPrefix: aksVirtualNetworkAddressPrefix
    aksNodeSubnetName: aksNodeSubnetName
    aksNodeSubnetAddressPrefix: aksNodeSubnetAddressPrefix
    aksApiServerSubnetName: aksApiServerSubnetName
    aksApiServerSubnetAddressPrefix: aksApiServerSubnetAddressPrefix
    associateExistingPolicyManagedNsgs: associateExistingPolicyManagedNsgs
  }
}

module aksIdentity './modules/aks-identity.bicep' = {
  name: 'private-aks-identity'
  scope: resourceGroup(demoResourceGroup.name)
  params: {
    location: location
    aksIdentityName: aksIdentityName
    aksVirtualNetworkName: aksVirtualNetworkName
    aksNodeSubnetName: aksNodeSubnetName
    aksApiServerSubnetName: aksApiServerSubnetName
  }
  dependsOn: [
    network
  ]
}

module bastion './modules/bastion.bicep' = {
  name: 'private-aks-bastion'
  scope: resourceGroup(demoResourceGroup.name)
  params: {
    location: location
    bastionName: bastionName
    bastionPublicIpName: bastionPublicIpName
    bastionSubnetId: network.outputs.bastionSubnetId
    scaleUnits: bastionScaleUnits
  }
}

module monitoring './modules/monitoring.bicep' = {
  name: 'private-aks-monitoring'
  scope: resourceGroup(demoResourceGroup.name)
  params: {
    location: location
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    applicationInsightsName: applicationInsightsName
  }
}

module aksCluster './modules/aks-cluster.bicep' = {
  name: 'private-aks-cluster'
  scope: resourceGroup(demoResourceGroup.name)
  params: {
    location: location
    aksClusterName: aksClusterName
    nodeResourceGroupName: nodeResourceGroupName
    aksIdentityId: aksIdentity.outputs.aksIdentityId
    aksNodeSubnetId: network.outputs.aksNodeSubnetId
    aksApiServerSubnetId: network.outputs.aksApiServerSubnetId
    sshPublicKey: sshPublicKey
    systemNodeVmSize: systemNodeVmSize
    systemNodeCount: systemNodeCount
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    enableContainerNetworkLogs: enableContainerNetworkLogs
  }
}

module aksMonitoring './modules/aks-monitoring.bicep' = {
  name: 'private-aks-telemetry'
  scope: resourceGroup(demoResourceGroup.name)
  params: {
    location: location
    aksClusterName: aksClusterName
    azureMonitorWorkspaceName: azureMonitorWorkspaceName
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    enableContainerNetworkLogs: enableContainerNetworkLogs
  }
  dependsOn: [
    aksCluster
  ]
}

module privateDnsLink './modules/private-dns-link.bicep' = {
  name: 'private-aks-management-dns-link'
  scope: resourceGroup(nodeResourceGroupName)
  params: {
    privateFqdn: aksCluster.outputs.privateFqdn
    managementVirtualNetworkId: network.outputs.managementVirtualNetworkId
  }
}

module sreAgent './modules/sre-agent.bicep' = {
  name: 'sre-agent'
  scope: resourceGroup(demoResourceGroup.name)
  params: {
    location: location
    sreAgentName: sreAgentName
    managedIdentityName: managedIdentityName
    aksClusterName: aksClusterName
    agentSubnetId: network.outputs.agentSubnetId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    applicationInsightsId: monitoring.outputs.applicationInsightsId
    applicationInsightsAppId: monitoring.outputs.applicationInsightsAppId
    applicationInsightsName: applicationInsightsName
    deployRoleAssignments: deployRoleAssignments
  }
}

output agentId string = sreAgent.outputs.agentId
output agentEndpoint string = sreAgent.outputs.agentEndpoint
output managedIdentityId string = sreAgent.outputs.managedIdentityId
output resourceGroupId string = demoResourceGroup.id
output aksClusterId string = aksCluster.outputs.aksClusterId
output nodeResourceGroup string = aksCluster.outputs.nodeResourceGroup
output privateFqdn string = aksCluster.outputs.privateFqdn
output azureMonitorWorkspaceId string = aksMonitoring.outputs.azureMonitorWorkspaceId
output managementVirtualNetworkId string = network.outputs.managementVirtualNetworkId
output aksVirtualNetworkId string = network.outputs.aksVirtualNetworkId
output agentSubnetId string = network.outputs.agentSubnetId
output aksNodeSubnetId string = network.outputs.aksNodeSubnetId
output aksApiServerSubnetId string = network.outputs.aksApiServerSubnetId
output aksIdentityId string = aksIdentity.outputs.aksIdentityId
output bastionId string = bastion.outputs.bastionId
output logAnalyticsWorkspaceId string = monitoring.outputs.logAnalyticsWorkspaceId
output applicationInsightsId string = monitoring.outputs.applicationInsightsId
output privateDnsLinkId string = privateDnsLink.outputs.privateDnsLinkId
