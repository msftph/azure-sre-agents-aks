@description('Azure region for Azure Bastion and its public IP address.')
param location string

@description('Name of the Azure Bastion resource.')
param bastionName string

@description('Name of the Standard public IP address used by Azure Bastion.')
param bastionPublicIpName string

@description('Resource ID of AzureBastionSubnet.')
param bastionSubnetId string

@minValue(2)
@maxValue(50)
@description('Number of Azure Bastion scale units.')
param scaleUnits int = 2

resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = {
  name: bastionPublicIpName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-07-01' = {
  name: bastionName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    enableTunneling: true
    scaleUnits: scaleUnits
    ipConfigurations: [
      {
        name: 'bastion-ip-configuration'
        properties: {
          subnet: {
            id: bastionSubnetId
          }
          publicIPAddress: {
            id: bastionPublicIp.id
          }
        }
      }
    ]
  }
}

output bastionId string = bastion.id
output bastionPublicIpId string = bastionPublicIp.id
