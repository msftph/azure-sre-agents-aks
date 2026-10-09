@description('Azure region of the Azure Monitor workspace.')
param location string

@description('Name of the AKS cluster.')
param aksClusterName string

@description('Resource ID of the AKS cluster.')
param aksClusterId string

@description('Resource ID of the Azure Monitor workspace.')
param azureMonitorWorkspaceId string

@description('Recording-rule recommendations discovered from Azure Monitor. Alert recommendations are excluded.')
param ruleGroups array

resource recordingRules 'Microsoft.AlertsManagement/prometheusRuleGroups@2023-03-01' = [for group in ruleGroups: {
  name: take('${group.name}-${aksClusterName}', 260)
  location: location
  properties: {
    scopes: [
      azureMonitorWorkspaceId
      aksClusterId
    ]
    clusterName: aksClusterName
    enabled: !contains(toLower(group.name), 'win')
    interval: 'PT1M'
    rules: group.rules
  }
}]
