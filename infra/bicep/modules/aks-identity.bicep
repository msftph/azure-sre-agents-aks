@description('Azure region for the AKS user-assigned managed identity.')
param location string

@description('Name of the user-assigned managed identity used by AKS.')
param aksIdentityName string

@description('Name of the customer-managed AKS virtual network.')
param aksVirtualNetworkName string

@description('Name of the AKS node subnet.')
param aksNodeSubnetName string

@description('Name of the AKS API server subnet.')
param aksApiServerSubnetName string

var networkContributorRoleId = '4d97b98b-1d4f-4787-a291-c67834d212e7'

resource aksIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: aksIdentityName
  location: location
}

resource aksVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-07-01' existing = {
  name: aksVirtualNetworkName
}

resource aksNodeSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' existing = {
  parent: aksVirtualNetwork
  name: aksNodeSubnetName
}

resource aksApiServerSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' existing = {
  parent: aksVirtualNetwork
  name: aksApiServerSubnetName
}

resource nodeSubnetNetworkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aksNodeSubnet.id, aksIdentity.id, networkContributorRoleId)
  scope: aksNodeSubnet
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', networkContributorRoleId)
    principalId: aksIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource apiServerSubnetNetworkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aksApiServerSubnet.id, aksIdentity.id, networkContributorRoleId)
  scope: aksApiServerSubnet
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', networkContributorRoleId)
    principalId: aksIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output aksIdentityId string = aksIdentity.id
output aksIdentityPrincipalId string = aksIdentity.properties.principalId
