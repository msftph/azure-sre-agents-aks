targetScope = 'resourceGroup'

@description('Azure region for private AKS networking and Azure Bastion.')
param location string = resourceGroup().location

@description('Name of the management virtual network used by SRE Agent and Bastion.')
param managementVirtualNetworkName string = 'vnet-sre-agent-aks-demo'

@description('Address space for the management virtual network.')
param managementVirtualNetworkAddressPrefix string = '10.250.0.0/24'

@description('Name of the subnet delegated to Azure SRE Agent.')
param agentSubnetName string = 'snet-sre-agent'

@description('Address prefix for the delegated SRE Agent subnet.')
param agentSubnetAddressPrefix string = '10.250.0.0/27'

@description('Address prefix for AzureBastionSubnet.')
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

@description('Name of the AKS user-assigned managed identity.')
param aksIdentityName string = 'id-aks-sre-agent-demo'

@description('Name of the Azure Bastion resource.')
param bastionName string = 'bas-sre-agent-aks-demo'

@description('Name of the Azure Bastion public IP address.')
param bastionPublicIpName string = 'pip-bas-sre-agent-aks-demo'

@minValue(2)
@maxValue(50)
@description('Number of Azure Bastion scale units.')
param bastionScaleUnits int = 2

module network './modules/network.bicep' = {
  name: 'private-aks-network'
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
  }
}

module aksIdentity './modules/aks-identity.bicep' = {
  name: 'private-aks-identity'
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
  params: {
    location: location
    bastionName: bastionName
    bastionPublicIpName: bastionPublicIpName
    bastionSubnetId: network.outputs.bastionSubnetId
    scaleUnits: bastionScaleUnits
  }
}

output managementVirtualNetworkId string = network.outputs.managementVirtualNetworkId
output aksVirtualNetworkId string = network.outputs.aksVirtualNetworkId
output agentSubnetId string = network.outputs.agentSubnetId
output aksNodeSubnetId string = network.outputs.aksNodeSubnetId
output aksApiServerSubnetId string = network.outputs.aksApiServerSubnetId
output aksIdentityId string = aksIdentity.outputs.aksIdentityId
output bastionId string = bastion.outputs.bastionId
