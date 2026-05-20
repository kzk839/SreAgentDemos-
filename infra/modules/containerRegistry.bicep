@description('ACR name (globally unique, alphanumeric only)')
param name string

@description('Azure region')
param location string

@description('ACR SKU (Premium required for Private Endpoint)')
param skuName string = 'Premium'

@description('Subnet ID for Private Endpoint')
param privateEndpointSubnetId string = ''

@description('Private DNS Zone ID for ACR')
param privateDnsZoneId string = ''

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: name
  location: location
  sku: {
    name: skuName
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: !empty(privateEndpointSubnetId) ? 'Disabled' : 'Enabled'
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-01-01' = if (!empty(privateEndpointSubnetId)) {
  name: '${name}-pe'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${name}-plsc'
        properties: {
          privateLinkServiceId: acr.id
          groupIds: [
            'registry'
          ]
        }
      }
    ]
  }
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = if (!empty(privateEndpointSubnetId) && !empty(privateDnsZoneId)) {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'acr-config'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

output id string = acr.id
output name string = acr.name
output loginServer string = acr.properties.loginServer
