@description('Azure region for the virtual network.')
param location string

@description('Name of the management virtual network used by SRE Agent and Bastion.')
param managementVirtualNetworkName string

@description('Address space for the management virtual network.')
param managementVirtualNetworkAddressPrefix string

@description('Name of the subnet delegated to Azure SRE Agent.')
param agentSubnetName string

@description('Address prefix for the delegated subnet.')
param agentSubnetAddressPrefix string

@description('Address prefix for the dedicated Azure Bastion subnet. Azure Bastion requires the subnet name AzureBastionSubnet and at least a /26.')
param bastionSubnetAddressPrefix string

@description('Name of the customer-managed AKS virtual network.')
param aksVirtualNetworkName string

@description('Address space for the customer-managed AKS virtual network.')
param aksVirtualNetworkAddressPrefix string

@description('Name of the AKS node subnet.')
param aksNodeSubnetName string

@description('Address prefix for the AKS node subnet.')
param aksNodeSubnetAddressPrefix string

@description('Name of the subnet delegated to the AKS API server.')
param aksApiServerSubnetName string

@description('Address prefix for the AKS API server subnet. API Server VNet Integration requires at least a /28.')
param aksApiServerSubnetAddressPrefix string

@description('Associate the policy-managed network security groups that already exist for each subnet.')
param associateExistingPolicyManagedNsgs bool = false

@description('Name of the policy-managed network security group for the SRE Agent subnet.')
param agentSubnetNetworkSecurityGroupName string = '${managementVirtualNetworkName}-${agentSubnetName}-nsg-${location}'

@description('Name of the policy-managed network security group for AzureBastionSubnet.')
param bastionSubnetNetworkSecurityGroupName string = '${managementVirtualNetworkName}-AzureBastionSubnet-nsg-${location}'

@description('Name of the policy-managed network security group for the AKS node subnet.')
param aksNodeSubnetNetworkSecurityGroupName string = '${aksVirtualNetworkName}-${aksNodeSubnetName}-nsg-${location}'

@description('Name of the policy-managed network security group for the AKS API server subnet.')
param aksApiServerSubnetNetworkSecurityGroupName string = '${aksVirtualNetworkName}-${aksApiServerSubnetName}-nsg-${location}'

resource agentSubnetNetworkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-07-01' existing = {
  name: agentSubnetNetworkSecurityGroupName
}

resource bastionSubnetNetworkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-07-01' existing = {
  name: bastionSubnetNetworkSecurityGroupName
}

resource aksNodeSubnetNetworkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-07-01' existing = {
  name: aksNodeSubnetNetworkSecurityGroupName
}

resource aksApiServerSubnetNetworkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-07-01' existing = {
  name: aksApiServerSubnetNetworkSecurityGroupName
}

resource managementVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: managementVirtualNetworkName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        managementVirtualNetworkAddressPrefix
      ]
    }
    subnets: [
      {
        name: agentSubnetName
        properties: {
          addressPrefix: agentSubnetAddressPrefix
          networkSecurityGroup: associateExistingPolicyManagedNsgs ? {
            id: agentSubnetNetworkSecurityGroup.id
          } : null
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
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnetAddressPrefix
          networkSecurityGroup: associateExistingPolicyManagedNsgs ? {
            id: bastionSubnetNetworkSecurityGroup.id
          } : null
        }
      }
    ]
  }
}

resource aksVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: aksVirtualNetworkName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        aksVirtualNetworkAddressPrefix
      ]
    }
    subnets: [
      {
        name: aksNodeSubnetName
        properties: {
          addressPrefix: aksNodeSubnetAddressPrefix
          networkSecurityGroup: associateExistingPolicyManagedNsgs ? {
            id: aksNodeSubnetNetworkSecurityGroup.id
          } : null
        }
      }
      {
        name: aksApiServerSubnetName
        properties: {
          addressPrefix: aksApiServerSubnetAddressPrefix
          networkSecurityGroup: associateExistingPolicyManagedNsgs ? {
            id: aksApiServerSubnetNetworkSecurityGroup.id
          } : null
          delegations: [
            {
              name: 'aks-api-server-delegation'
              properties: {
                serviceName: 'Microsoft.ContainerService/managedClusters'
              }
            }
          ]
        }
      }
    ]
  }
}

resource managementToAksPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-07-01' = {
  parent: managementVirtualNetwork
  name: 'management-to-aks'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
    peerCompleteVnets: true
    remoteVirtualNetwork: {
      id: aksVirtualNetwork.id
    }
  }
}

resource aksToManagementPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-07-01' = {
  parent: aksVirtualNetwork
  name: 'aks-to-management'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
    peerCompleteVnets: true
    remoteVirtualNetwork: {
      id: managementVirtualNetwork.id
    }
  }
}

resource agentSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' existing = {
  parent: managementVirtualNetwork
  name: agentSubnetName
}

resource bastionSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' existing = {
  parent: managementVirtualNetwork
  name: 'AzureBastionSubnet'
}

resource aksNodeSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' existing = {
  parent: aksVirtualNetwork
  name: aksNodeSubnetName
}

resource aksApiServerSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' existing = {
  parent: aksVirtualNetwork
  name: aksApiServerSubnetName
}

output managementVirtualNetworkId string = managementVirtualNetwork.id
output aksVirtualNetworkId string = aksVirtualNetwork.id
output agentSubnetId string = agentSubnet.id
output bastionSubnetId string = bastionSubnet.id
output aksNodeSubnetId string = aksNodeSubnet.id
output aksApiServerSubnetId string = aksApiServerSubnet.id
