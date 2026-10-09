targetScope = 'subscription'

@description('Name of the resource group for the demo.')
param resourceGroupName string

@description('Azure region for the demo resource group.')
param location string

resource demoResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

output resourceGroupId string = demoResourceGroup.id
