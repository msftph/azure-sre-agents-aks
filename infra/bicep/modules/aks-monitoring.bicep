@description('Azure region for AKS telemetry resources.')
param location string

@description('Name of the existing AKS cluster.')
param aksClusterName string

@description('Name of the Azure Monitor workspace for managed Prometheus.')
param azureMonitorWorkspaceName string

@description('Resource ID of the Log Analytics workspace for Container Insights.')
param logAnalyticsWorkspaceId string

@description('Include ACNS network logs and use high-scale container log ingestion.')
param enableContainerNetworkLogs bool = false

resource aksCluster 'Microsoft.ContainerService/managedClusters@2025-07-01' existing = {
  name: aksClusterName
}

resource azureMonitorWorkspace 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: azureMonitorWorkspaceName
  location: location
  properties: {}
}

resource prometheusEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: 'dce-prom-${uniqueString(aksCluster.id)}'
  location: location
  kind: 'Linux'
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

resource prometheusRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-prom-${uniqueString(aksCluster.id)}'
  location: location
  kind: 'Linux'
  properties: {
    dataCollectionEndpointId: prometheusEndpoint.id
    dataSources: {
      prometheusForwarder: [
        {
          name: 'prometheus'
          streams: [
            'Microsoft-PrometheusMetrics'
          ]
        }
      ]
    }
    destinations: {
      monitoringAccounts: [
        {
          name: 'prometheus-workspace'
          accountResourceId: azureMonitorWorkspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-PrometheusMetrics'
        ]
        destinations: [
          'prometheus-workspace'
        ]
      }
    ]
  }
}

resource prometheusAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'ContainerInsightsMetricsExtension'
  scope: aksCluster
  properties: {
    dataCollectionRuleId: prometheusRule.id
  }
}

var containerInsightsStreams = enableContainerNetworkLogs ? [
  'Microsoft-ContainerLogV2-HighScale'
  'Microsoft-KubeEvents'
  'Microsoft-KubePodInventory'
  'Microsoft-KubeNodeInventory'
  'Microsoft-KubePVInventory'
  'Microsoft-KubeServices'
  'Microsoft-KubeMonAgentEvents'
  'Microsoft-InsightsMetrics'
  'Microsoft-ContainerInventory'
  'Microsoft-ContainerNodeInventory'
  'Microsoft-Perf'
  'Microsoft-ContainerNetworkLogs'
] : [
  'Microsoft-ContainerInsights-Group-Default'
]

resource containerInsightsEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = if (enableContainerNetworkLogs) {
  name: 'dce-logs-${uniqueString(aksCluster.id)}'
  location: location
  kind: 'Linux'
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

resource containerInsightsRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-logs-${uniqueString(aksCluster.id)}'
  location: location
  kind: 'Linux'
  properties: {
    dataCollectionEndpointId: enableContainerNetworkLogs ? containerInsightsEndpoint.id : null
    dataSources: {
      extensions: [
        {
          name: 'ContainerInsightsExtension'
          extensionName: 'ContainerInsights'
          streams: containerInsightsStreams
          extensionSettings: {
            dataCollectionSettings: {
              enableContainerLogV2: true
            }
          }
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'container-insights-workspace'
          workspaceResourceId: logAnalyticsWorkspaceId
        }
      ]
    }
    dataFlows: [
      {
        streams: containerInsightsStreams
        destinations: [
          'container-insights-workspace'
        ]
      }
    ]
  }
}

resource containerInsightsAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'ContainerInsightsExtension'
  scope: aksCluster
  properties: {
    dataCollectionRuleId: containerInsightsRule.id
  }
}

output azureMonitorWorkspaceId string = azureMonitorWorkspace.id
