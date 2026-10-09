targetScope = 'subscription'

resource publicIpFeature 'Microsoft.Features/featureProviders/subscriptionFeatureRegistrations@2021-07-01' = {
  name: 'Microsoft.Network/AllowBringYourOwnPublicIpAddress'
  properties: {}
}
