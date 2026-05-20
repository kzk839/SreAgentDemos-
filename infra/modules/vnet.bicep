@description('Virtual network name')
param name string

@description('Azure region')
param location string

@description('VNet address space (CIDR)')
param addressPrefix string

@description('Subnet configurations: [{name, addressPrefix, nsgId?, routeTableId?, delegations?}]')
param subnets array

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: name
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: [for subnet in subnets: {
      name: subnet.name
      properties: union(
        {
          addressPrefix: subnet.addressPrefix
        },
        contains(subnet, 'nsgId') ? {
          networkSecurityGroup: {
            id: subnet.nsgId
          }
        } : {},
        contains(subnet, 'routeTableId') ? {
          routeTable: {
            id: subnet.routeTableId
          }
        } : {},
        contains(subnet, 'delegations') ? {
          delegations: subnet.delegations
        } : {}
      )
    }]
  }
}

output id string = virtualNetwork.id
output name string = virtualNetwork.name
output subnets array = virtualNetwork.properties.subnets
