@description('Azure region for the SRE Agent.')
param location string

@description('Name of the Azure SRE Agent.')
param sreAgentName string

@description('Name of the user-assigned managed identity.')
param managedIdentityName string

@description('Name of the existing AKS cluster.')
param aksClusterName string

@description('Resource ID of the subnet delegated to Microsoft.App/environments.')
param agentSubnetId string

@description('Resource ID of the Log Analytics workspace.')
param logAnalyticsWorkspaceId string

@description('Resource ID of the Application Insights component.')
param applicationInsightsId string

@description('Application ID of the Application Insights component.')
param applicationInsightsAppId string

@description('Name of the Application Insights component.')
param applicationInsightsName string

@description('Create role assignments required by the AKS incident-response demo.')
param deployRoleAssignments bool

var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
var monitoringContributorRoleId = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'
var aksClusterAdminRoleId = '0ab0b1a8-8aac-4efd-b8c2-3ee1fb270be8'
var aksContributorRoleId = 'ed7f3fbd-7b88-4dd4-9017-9adb7ce333f8'
var sreAgentAdministratorRoleId = 'e79298df-d852-4c6d-84f9-5d13249d1e55'

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: managedIdentityName
  location: location
  properties: {
    isolationScope: 'Regional'
  }
}

resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-09-01' existing = {
  name: aksClusterName
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: applicationInsightsName
}

#disable-next-line BCP081
resource sreAgent 'Microsoft.App/agents@2025-05-01-preview' = {
  name: sreAgentName
  location: location
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    vnetConfiguration: {
      subnetResourceId: agentSubnetId
    }
    sandboxConfiguration: {
      egress: {
        mode: 'AzureVNet'
        allowHttpMcpServerNetworkAccess: true
        allowedCodeRepositories: []
        allowedHosts: []
        allowedRegistries: []
        vnetConfiguration: {
          usePrivateDnsResolution: true
        }
      }
      packages: []
    }
    knowledgeGraphConfiguration: {
      identity: managedIdentity.id
      managedResources: [
        resourceGroup().id
      ]
    }
    actionConfiguration: {
      accessLevel: 'High'
      identity: managedIdentity.id
      mode: 'autonomous'
    }
    defaultModel: {
      name: 'Automatic'
      provider: 'Anthropic'
    }
    experimentalSettings: {
      EnableConnectorsV2: true
      EnableDevOpsTools: true
      EnablePythonTools: true
      EnableV2AgentLoop: true
      EnableWorkspaceTools: true
    }
    incidentManagementConfiguration: {
      connectionName: 'azmonitor'
      type: 'AzMonitor'
    }
    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: applicationInsightsAppId
        applicationInsightsResourceId: applicationInsightsId
        connectionString: applicationInsights.properties.ConnectionString
      }
    }
    monthlyAgentUnitLimit: 10000
    upgradeChannel: 'Stable'
  }
}

#disable-next-line BCP081
resource applicationInsightsConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: sreAgent
  name: 'app-insights'
  properties: {
    dataConnectorType: 'AppInsights'
    dataSource: applicationInsightsId
    extendedProperties: {
      armResourceId: applicationInsightsId
      resource: {
        name: last(split(applicationInsightsId, '/'))
      }
    }
    identity: 'system'
  }
}

#disable-next-line BCP081
resource logAnalyticsConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: sreAgent
  name: 'aks-demo-logs'
  properties: {
    dataConnectorType: 'LogAnalytics'
    dataSource: logAnalyticsWorkspaceId
    extendedProperties: {
      armResourceId: logAnalyticsWorkspaceId
      resource: {
        name: last(split(logAnalyticsWorkspaceId, '/'))
      }
    }
    identity: 'system'
  }
}

#disable-next-line BCP081
resource azureMonitorConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: sreAgent
  name: 'azure-monitor'
  properties: {
    dataConnectorType: 'MonitorClient'
    dataSource: 'n/a'
    identity: 'system'
  }
}

resource uamiReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments) {
  name: guid(resourceGroup().id, managedIdentity.id, readerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource uamiMonitoringReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments) {
  name: guid(resourceGroup().id, managedIdentity.id, monitoringReaderRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReaderRoleId)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource uamiMonitoringContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments) {
  name: guid(resourceGroup().id, managedIdentity.id, monitoringContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringContributorRoleId)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource uamiLogAnalyticsReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments) {
  name: guid(resourceGroup().id, managedIdentity.id, logAnalyticsReaderRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsReaderRoleId)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource uamiAksClusterAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments) {
  name: guid(aksCluster.id, managedIdentity.id, aksClusterAdminRoleId)
  scope: aksCluster
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aksClusterAdminRoleId)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource uamiAksContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments) {
  name: guid(aksCluster.id, managedIdentity.id, aksContributorRoleId)
  scope: aksCluster
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aksContributorRoleId)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource systemReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments) {
  name: guid(resourceGroup().id, sreAgent.id, readerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource systemMonitoringReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments) {
  name: guid(resourceGroup().id, sreAgent.id, monitoringReaderRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReaderRoleId)
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource systemLogAnalyticsReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments) {
  name: guid(resourceGroup().id, sreAgent.id, logAnalyticsReaderRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsReaderRoleId)
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource deployerAgentAdministrator 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments) {
  name: guid(sreAgent.id, deployer().objectId, sreAgentAdministratorRoleId)
  scope: sreAgent
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sreAgentAdministratorRoleId)
    principalId: deployer().objectId
  }
}

output agentId string = sreAgent.id
output agentEndpoint string = sreAgent.properties.agentEndpoint
output managedIdentityId string = managedIdentity.id
