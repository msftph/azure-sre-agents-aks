using './main.bicep'

param location = 'swedencentral'
param aksClusterName = 'Azure-SRE-Agent-Demo-Cluster'
param sreAgentName = 'sre-agent-aks-demo'
param managedIdentityName = 'id-sre-agent-aks-demo'
param logAnalyticsWorkspaceName = 'law-sre-agent-aks-demo'
param applicationInsightsName = 'appi-sre-agent-aks-demo'
param virtualNetworkName = 'vnet-sre-agent-aks-demo'
param virtualNetworkAddressPrefix = '10.250.0.0/24'
param agentSubnetName = 'snet-sre-agent'
param agentSubnetAddressPrefix = '10.250.0.0/27'

param deployRoleAssignments = true
