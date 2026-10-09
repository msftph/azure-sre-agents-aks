@description('Azure region for the private AKS cluster.')
param location string

@description('Name of the private AKS cluster.')
param aksClusterName string

@description('Resource ID of the AKS user-assigned managed identity.')
param aksIdentityId string

@description('Resource ID of the AKS node subnet.')
param aksNodeSubnetId string

@description('Resource ID of the delegated AKS API server subnet.')
param aksApiServerSubnetId string

@description('SSH public key for the Linux nodes. Never supply a private key.')
@minLength(1)
param sshPublicKey string

@description('Linux administrator username for the AKS nodes.')
param adminUsername string = 'azureuser'

@description('VM size for the system node pool.')
param systemNodeVmSize string = 'Standard_D4s_v5'

@minValue(1)
@description('Number of nodes in the system node pool.')
param systemNodeCount int = 3

@description('Log Analytics workspace resource ID for Container Insights.')
param logAnalyticsWorkspaceId string

@description('Forward ACNS container network logs to Container Insights using high-scale collection.')
param enableContainerNetworkLogs bool = false

resource aksCluster 'Microsoft.ContainerService/managedClusters@2025-07-01' = {
  name: aksClusterName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${aksIdentityId}': {}
    }
  }
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  properties: {
    dnsPrefix: 'aks-${uniqueString(resourceGroup().id, aksClusterName)}'
    enableRBAC: true
    linuxProfile: {
      adminUsername: adminUsername
      ssh: {
        publicKeys: [
          {
            keyData: sshPublicKey
          }
        ]
      }
    }
    agentPoolProfiles: [
      {
        name: 'nodepool1'
        count: systemNodeCount
        vmSize: systemNodeVmSize
        osType: 'Linux'
        osSKU: 'Ubuntu'
        type: 'VirtualMachineScaleSets'
        mode: 'System'
        vnetSubnetID: aksNodeSubnetId
        nodeTaints: [
          'CriticalAddonsOnly=true:NoExecute'
        ]
      }
    ]
    apiServerAccessProfile: {
      enableVnetIntegration: true
      subnetId: aksApiServerSubnetId
      enablePrivateCluster: true
      enablePrivateClusterPublicFQDN: false
      privateDNSZone: 'system'
    }
    nodeProvisioningProfile: {
      mode: 'Auto'
    }
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkDataplane: 'cilium'
      podCidr: '10.244.0.0/16'
      serviceCidr: '10.0.0.0/16'
      dnsServiceIP: '10.0.0.10'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
      advancedNetworking: {
        enabled: true
        observability: {
          enabled: true
        }
        security: {
          enabled: true
        }
      }
    }
    azureMonitorProfile: {
      metrics: {
        enabled: true
      }
    }
    addonProfiles: {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logAnalyticsWorkspaceId
          useAADAuth: 'true'
          enableRetinaNetworkFlags: enableContainerNetworkLogs ? 'true' : 'false'
        }
      }
    }
    workloadAutoScalerProfile: {
      keda: {
        enabled: true
      }
    }
  }
}

output aksClusterId string = aksCluster.id
output nodeResourceGroup string = aksCluster.properties.nodeResourceGroup
output privateFqdn string = aksCluster.properties.privateFQDN
