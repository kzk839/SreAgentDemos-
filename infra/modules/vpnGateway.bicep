@description('VPN Gateway name')
param name string

@description('Azure region')
param location string

@description('GatewaySubnet resource ID')
param gatewaySubnetId string

@description('VPN Gateway SKU')
param skuName string = 'VpnGw1AZ'

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: '${name}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  zones: ['1', '2', '3']
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource vpnGateway 'Microsoft.Network/virtualNetworkGateways@2024-01-01' = {
  name: name
  location: location
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    enableBgp: false
    sku: {
      name: skuName
      tier: skuName
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
          subnet: {
            id: gatewaySubnetId
          }
        }
      }
    ]
  }
}

output id string = vpnGateway.id
output name string = vpnGateway.name
