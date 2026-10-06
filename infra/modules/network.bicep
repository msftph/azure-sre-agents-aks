@description('Azure region for the virtual network.')
param location string

@description('Name of the virtual network.')
param virtualNetworkName string

@description('Address space for the virtual network.')
param virtualNetworkAddressPrefix string

@description('Name of the subnet delegated to Azure SRE Agent.')
param agentSubnetName string

@description('Address prefix for the delegated subnet.')
param agentSubnetAddressPrefix string

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: virtualNetworkName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        virtualNetworkAddressPrefix
      ]
    }
    subnets: [
      {
        name: agentSubnetName
        properties: {
          addressPrefix: agentSubnetAddressPrefix
          delegations: [
            {
              name: 'sre-agent-delegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
    ]
  }
}

resource agentSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' existing = {
  parent: virtualNetwork
  name: agentSubnetName
}

output virtualNetworkId string = virtualNetwork.id
output agentSubnetId string = agentSubnet.id
