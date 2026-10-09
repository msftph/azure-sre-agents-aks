using './private-cluster-prereqs.bicep'

param location = 'swedencentral'
param aksClusterName = 'Azure-SRE-Agent-Demo-Cluster'
param sshPublicKey = readEnvironmentVariable('AKS_SSH_PUBLIC_KEY')
param systemNodeVmSize = 'Standard_D4s_v5'
param systemNodeCount = 3
param logAnalyticsWorkspaceName = 'law-sre-agent-aks-demo'
param applicationInsightsName = 'appi-sre-agent-aks-demo'
param azureMonitorWorkspaceName = 'amw-sre-agent-aks-demo'
param enableContainerNetworkLogs = false
param managementVirtualNetworkName = 'vnet-sre-agent-aks-demo'
param managementVirtualNetworkAddressPrefix = '10.250.0.0/24'
param agentSubnetName = 'snet-sre-agent'
param agentSubnetAddressPrefix = '10.250.0.0/27'
param bastionSubnetAddressPrefix = '10.250.0.64/26'

param aksVirtualNetworkName = 'vnet-aks-sre-agent-demo'
param aksVirtualNetworkAddressPrefix = '10.224.0.0/16'
param aksNodeSubnetName = 'snet-aks-nodes'
param aksNodeSubnetAddressPrefix = '10.224.0.0/20'
param aksApiServerSubnetName = 'snet-aks-api-server'
param aksApiServerSubnetAddressPrefix = '10.224.16.0/28'
param associateExistingPolicyManagedNsgs = true

param aksIdentityName = 'id-aks-sre-agent-demo'
param bastionName = 'bas-sre-agent-aks-demo'
param bastionPublicIpName = 'pip-bas-sre-agent-aks-demo'
param bastionScaleUnits = 2
