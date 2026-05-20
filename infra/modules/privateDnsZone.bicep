@description('Private DNS Zone name (e.g. privatelink.azurecr.io)')
param zoneName string

@description('VNet links: [{name, vnetId}]')
param vnetLinks array = []

@description('A records: [{name, ipv4Address}]')
param aRecords array = []

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: zoneName
  location: 'global'
}

resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for link in vnetLinks: {
    parent: privateDnsZone
    name: link.name
    location: 'global'
    properties: {
      virtualNetwork: {
        id: link.vnetId
      }
      registrationEnabled: false
    }
  }
]

resource aRecord 'Microsoft.Network/privateDnsZones/A@2024-06-01' = [
  for record in aRecords: {
    parent: privateDnsZone
    name: record.name
    properties: {
      ttl: 3600
      aRecords: [
        {
          ipv4Address: record.ipv4Address
        }
      ]
    }
  }
]

output id string = privateDnsZone.id
output name string = privateDnsZone.name
