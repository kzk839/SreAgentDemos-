@description('Azure Firewall name')
param name string

@description('Azure region')
param location string

@description('AzureFirewallSubnet resource ID')
param subnetId string

@description('Internal address prefixes for firewall rules')
param internalAddressPrefixes array

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: '${name}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2024-01-01' = {
  name: '${name}-policy'
  location: location
  properties: {
    sku: {
      tier: 'Basic'
    }
    threatIntelMode: 'Alert'
  }
}

resource ruleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-01-01' = {
  parent: firewallPolicy
  name: 'DefaultRuleCollectionGroup'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'AllowInternalTraffic'
        priority: 100
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'AllowAllInternal'
            sourceAddresses: internalAddressPrefixes
            destinationAddresses: internalAddressPrefixes
            destinationPorts: [
              '*'
            ]
            ipProtocols: [
              'Any'
            ]
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'AllowInternetOutbound'
        priority: 200
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'AllowHttpHttps'
            sourceAddresses: internalAddressPrefixes
            destinationAddresses: [
              '*'
            ]
            destinationPorts: [
              '80'
              '443'
            ]
            ipProtocols: [
              'TCP'
            ]
          }
          {
            ruleType: 'NetworkRule'
            name: 'AllowDns'
            sourceAddresses: internalAddressPrefixes
            destinationAddresses: [
              '*'
            ]
            destinationPorts: [
              '53'
            ]
            ipProtocols: [
              'UDP'
              'TCP'
            ]
          }
        ]
      }
    ]
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2024-01-01' = {
  name: name
  location: location
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Basic'
    }
    firewallPolicy: {
      id: firewallPolicy.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
  dependsOn: [
    ruleCollectionGroup
  ]
}

output privateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
output publicIp string = publicIp.properties.ipAddress
output id string = firewall.id
