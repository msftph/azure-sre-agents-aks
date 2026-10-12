@description('Private FQDN of the AKS cluster.')
param privateFqdn string

@description('Resource ID of the management virtual network.')
param managementVirtualNetworkId string

var privateDnsZoneName = join(skip(split(privateFqdn, '.'), 1), '.')

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: privateDnsZoneName
}

resource managementLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: 'link-vnet-sre-agent-aks-demo'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: managementVirtualNetworkId
    }
  }
}

output privateDnsLinkId string = managementLink.id
