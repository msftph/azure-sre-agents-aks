targetScope = 'resourceGroup'

@description('Azure region for the SRE Agent resources.')
param location string = resourceGroup().location

@description('Name of the existing AKS cluster the SRE Agent manages.')
param aksClusterName string

@description('Name of the Azure SRE Agent resource.')
param sreAgentName string = 'sre-agent-aks-demo'

@description('Name of the user-assigned managed identity used by the SRE Agent.')
param managedIdentityName string = 'id-sre-agent-aks-demo'

@description('Name of the Log Analytics workspace used by the SRE Agent.')
param logAnalyticsWorkspaceName string = 'law-sre-agent-aks-demo'

@description('Name of the Application Insights component used by the SRE Agent.')
param applicationInsightsName string = 'appi-sre-agent-aks-demo'

@description('Name of the virtual network used for SRE Agent VNet integration.')
param virtualNetworkName string = 'vnet-sre-agent-aks-demo'

@description('Address space for the SRE Agent virtual network.')
param virtualNetworkAddressPrefix string = '10.250.0.0/24'

@description('Name of the delegated SRE Agent subnet.')
param agentSubnetName string = 'snet-sre-agent'

@description('Address prefix for the delegated SRE Agent subnet. Azure SRE Agent requires at least a /27.')
param agentSubnetAddressPrefix string = '10.250.0.0/27'

@description('Create the role assignments required by the demo. Set false when equivalent assignments already exist.')
param deployRoleAssignments bool = true

module network './modules/network.bicep' = {
  name: 'sre-agent-network'
  params: {
    location: location
    virtualNetworkName: virtualNetworkName
    virtualNetworkAddressPrefix: virtualNetworkAddressPrefix
    agentSubnetName: agentSubnetName
    agentSubnetAddressPrefix: agentSubnetAddressPrefix
  }
}

module monitoring './modules/monitoring.bicep' = {
  name: 'sre-agent-monitoring'
  params: {
    location: location
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    applicationInsightsName: applicationInsightsName
  }
}

module sreAgent './modules/sre-agent.bicep' = {
  name: 'sre-agent'
  params: {
    location: location
    sreAgentName: sreAgentName
    managedIdentityName: managedIdentityName
    aksClusterName: aksClusterName
    agentSubnetId: network.outputs.agentSubnetId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    applicationInsightsId: monitoring.outputs.applicationInsightsId
    applicationInsightsAppId: monitoring.outputs.applicationInsightsAppId
    deployRoleAssignments: deployRoleAssignments
  }
}

output agentId string = sreAgent.outputs.agentId
output agentEndpoint string = sreAgent.outputs.agentEndpoint
output managedIdentityId string = sreAgent.outputs.managedIdentityId
output virtualNetworkId string = network.outputs.virtualNetworkId
output agentSubnetId string = network.outputs.agentSubnetId
output logAnalyticsWorkspaceId string = monitoring.outputs.logAnalyticsWorkspaceId
output applicationInsightsId string = monitoring.outputs.applicationInsightsId
