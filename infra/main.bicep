// ============================================================
// SRE Agent Demo - Hub-Spoke Infrastructure (PaaS edition)
// ============================================================
// Topology:
//   Hub VNet (10.1.0.0/16) --[Peering]--> Spoke1 VNet (10.2.0.0/16)  Container Apps + ACR + SQL (PaaS)
//   Hub VNet --[Peering]--> Spoke2 VNet (10.3.0.0/16)  VM (Spoke 間テスト用)
//   All cross-VNet traffic routed through Azure Firewall
// ============================================================

targetScope = 'resourceGroup'

// ============================================================
// Parameters
// ============================================================
@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Resource name prefix')
param prefix string = 'sre-demo'

@description('VM admin username')
param adminUsername string

@secure()
@description('VM admin password')
param adminPassword string

@description('VM size for all VMs')
param vmSize string = 'Standard_B2s'

@description('SQL admin username')
param sqlAdminUsername string

@secure()
@description('SQL admin password')
param sqlAdminPassword string

@description('Email address for alert notifications')
param notificationEmail string

// ============================================================
// Variables
// ============================================================
var hubPrefix = '10.1.0.0/16'
var spoke1Prefix = '10.2.0.0/16'
var spoke2Prefix = '10.3.0.0/16'
var allPrefixes = [
  hubPrefix
  spoke1Prefix
  spoke2Prefix
]
var acrName = '${replace(prefix, '-', '')}acr${uniqueString(resourceGroup().id)}'
var sqlServerName = '${prefix}-sql-${uniqueString(resourceGroup().id)}'

// ============================================================
// Monitoring
// ============================================================
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-law'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${prefix}-appi'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// ============================================================
// Data Collection Rule (performance counters + event logs)
// ============================================================
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: '${prefix}-dcr-windows'
  location: location
  properties: {
    dataSources: {
      performanceCounters: [
        {
          name: 'perfCounterDataSource'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            '\\Processor(_Total)\\% Processor Time'
            '\\Memory\\Available MBytes'
            '\\Memory\\% Committed Bytes In Use'
            '\\LogicalDisk(_Total)\\% Free Space'
            '\\LogicalDisk(_Total)\\Disk Reads/sec'
            '\\LogicalDisk(_Total)\\Disk Writes/sec'
            '\\Network Interface(*)\\Bytes Total/sec'
          ]
        }
      ]
      windowsEventLogs: [
        {
          name: 'eventLogDataSource'
          streams: [
            'Microsoft-Event'
          ]
          xPathQueries: [
            'Application!*[System[(Level=1 or Level=2 or Level=3)]]'
            'System!*[System[(Level=1 or Level=2 or Level=3)]]'
            'Security!*[System[(band(Keywords,13510798882111488))]]'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'logAnalyticsDest'
          workspaceResourceId: logAnalytics.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-Perf'
          'Microsoft-Event'
        ]
        destinations: [
          'logAnalyticsDest'
        ]
      }
    ]
  }
}

// ============================================================
// NSG (shared for VM subnets)
// ============================================================
resource nsgDefault 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: '${prefix}-nsg-default'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowRdpInternal'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.0.0/8'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'AllowIcmpInternal'
        properties: {
          priority: 1010
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Icmp'
          sourceAddressPrefix: '10.0.0.0/8'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// NSG for Spoke1 Private Endpoints subnet
resource nsgPrivateEndpoints 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: '${prefix}-nsg-private-endpoints'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowInternalInbound'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.0.0/8'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowSqlInbound'
        properties: {
          priority: 1010
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.0.0/8'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '1433'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ============================================================
// VNets - Hub
// ============================================================

// Hub VNet: AzureFirewallSubnet + default subnet
module vnetHub 'modules/vnet.bicep' = {
  name: 'deploy-vnet-hub'
  params: {
    name: '${prefix}-vnet-hub'
    location: location
    addressPrefix: hubPrefix
    subnets: [
      { name: 'AzureFirewallSubnet', addressPrefix: '10.1.1.0/26' }
      { name: 'sn-default', addressPrefix: '10.1.2.0/24', nsgId: nsgDefault.id }
    ]
  }
}

// ============================================================
// Azure Firewall (in Hub VNet)
// ============================================================
module azureFirewall 'modules/azureFirewall.bicep' = {
  name: 'deploy-firewall'
  params: {
    name: '${prefix}-afw'
    location: location
    subnetId: vnetHub.outputs.subnets[0].id // AzureFirewallSubnet
    internalAddressPrefixes: allPrefixes
  }
}

// ============================================================
// Route Tables (next hop = Azure Firewall private IP)
// ============================================================

// Spoke1: internal routes only (no 0.0.0.0/0 to preserve Container Apps Azure service access)
resource rtSpoke1 'Microsoft.Network/routeTables@2024-01-01' = {
  name: '${prefix}-rt-spoke1'
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'to-hub'
        properties: {
          addressPrefix: hubPrefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: azureFirewall.outputs.privateIp
        }
      }
      {
        name: 'to-spoke2'
        properties: {
          addressPrefix: spoke2Prefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: azureFirewall.outputs.privateIp
        }
      }
    ]
  }
}

// Spoke2: full UDR including internet (VM subnet)
resource rtSpoke2 'Microsoft.Network/routeTables@2024-01-01' = {
  name: '${prefix}-rt-spoke2'
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'to-internet'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: azureFirewall.outputs.privateIp
        }
      }
      {
        name: 'to-hub'
        properties: {
          addressPrefix: hubPrefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: azureFirewall.outputs.privateIp
        }
      }
      {
        name: 'to-spoke1'
        properties: {
          addressPrefix: spoke1Prefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: azureFirewall.outputs.privateIp
        }
      }
    ]
  }
}

// Hub default: route spoke traffic through FW (for Hub VM → Spoke)
resource rtHubDefault 'Microsoft.Network/routeTables@2024-01-01' = {
  name: '${prefix}-rt-hub-default'
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'to-spoke1'
        properties: {
          addressPrefix: spoke1Prefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: azureFirewall.outputs.privateIp
        }
      }
      {
        name: 'to-spoke2'
        properties: {
          addressPrefix: spoke2Prefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: azureFirewall.outputs.privateIp
        }
      }
    ]
  }
}

// ============================================================
// VNets - Spokes (depend on route tables)
// ============================================================

// Spoke1: PaaS (Container Apps + Private Endpoints)
module vnetSpoke1 'modules/vnet.bicep' = {
  name: 'deploy-vnet-spoke1'
  params: {
    name: '${prefix}-vnet-spoke1'
    location: location
    addressPrefix: spoke1Prefix
    subnets: [
      {
        name: 'sn-container-apps'
        addressPrefix: '10.2.0.0/23'
        routeTableId: rtSpoke1.id
        delegations: [
          {
            name: 'Microsoft.App.environments'
            properties: {
              serviceName: 'Microsoft.App/environments'
            }
          }
        ]
      }
      {
        name: 'sn-private-endpoints'
        addressPrefix: '10.2.2.0/24'
        nsgId: nsgPrivateEndpoints.id
      }
    ]
  }
}

// Spoke2: VM for Spoke-to-Spoke testing
module vnetSpoke2 'modules/vnet.bicep' = {
  name: 'deploy-vnet-spoke2'
  params: {
    name: '${prefix}-vnet-spoke2'
    location: location
    addressPrefix: spoke2Prefix
    subnets: [
      { name: 'sn-default', addressPrefix: '10.3.1.0/24', nsgId: nsgDefault.id, routeTableId: rtSpoke2.id }
    ]
  }
}

// ============================================================
// Hub subnet updated after FW/RT ready
// ============================================================
resource hubDefaultSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = {
  name: '${prefix}-vnet-hub/sn-default'
  properties: {
    addressPrefix: '10.1.2.0/24'
    networkSecurityGroup: {
      id: nsgDefault.id
    }
    routeTable: {
      id: rtHubDefault.id
    }
  }
}

// ============================================================
// Private DNS Zones
// ============================================================
module dnsZoneAcr 'modules/privateDnsZone.bicep' = {
  name: 'deploy-dns-acr'
  params: {
    zoneName: 'privatelink.azurecr.io'
    vnetLinks: [
      { name: 'link-hub', vnetId: vnetHub.outputs.id }
      { name: 'link-spoke1', vnetId: vnetSpoke1.outputs.id }
      { name: 'link-spoke2', vnetId: vnetSpoke2.outputs.id }
    ]
  }
}

module dnsZoneSql 'modules/privateDnsZone.bicep' = {
  name: 'deploy-dns-sql'
  params: {
    zoneName: 'privatelink${environment().suffixes.sqlServerHostname}'
    vnetLinks: [
      { name: 'link-hub', vnetId: vnetHub.outputs.id }
      { name: 'link-spoke1', vnetId: vnetSpoke1.outputs.id }
      { name: 'link-spoke2', vnetId: vnetSpoke2.outputs.id }
    ]
  }
}

// ============================================================
// ACR (Premium for Private Endpoint support)
// ============================================================
module containerRegistry 'modules/containerRegistry.bicep' = {
  name: 'deploy-acr'
  params: {
    name: acrName
    location: location
    skuName: 'Premium'
    privateEndpointSubnetId: vnetSpoke1.outputs.subnets[1].id // sn-private-endpoints
    privateDnsZoneId: dnsZoneAcr.outputs.id
  }
}

// ============================================================
// Azure SQL Database
// ============================================================
module sqlDatabase 'modules/sqlDatabase.bicep' = {
  name: 'deploy-sql'
  params: {
    serverName: sqlServerName
    databaseName: '${prefix}-sqldb'
    location: location
    adminUsername: sqlAdminUsername
    adminPassword: sqlAdminPassword
    skuName: 'Basic'
    privateEndpointSubnetId: vnetSpoke1.outputs.subnets[1].id // sn-private-endpoints
    privateDnsZoneId: dnsZoneSql.outputs.id
    logAnalyticsWorkspaceId: logAnalytics.id
  }
}

// ============================================================
// Managed Identity + RBAC (for Container App → ACR)
// ============================================================
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-id-app'
  location: location
}

resource acrRef 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, acrName, '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  scope: acrRef
  properties: {
    principalId: managedIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d' // AcrPull
    )
    principalType: 'ServicePrincipal'
  }
  dependsOn: [
    containerRegistry
  ]
}

// ============================================================
// Container Apps (Internal Environment in Spoke1 VNet)
// ============================================================
module containerApps 'modules/containerApps.bicep' = {
  name: 'deploy-container-apps'
  params: {
    environmentName: '${prefix}-cae'
    appName: '${prefix}-app'
    location: location
    infrastructureSubnetId: vnetSpoke1.outputs.subnets[0].id // sn-container-apps
    logAnalyticsCustomerId: logAnalytics.properties.customerId
    logAnalyticsSharedKey: logAnalytics.listKeys().primarySharedKey
    appInsightsConnectionString: appInsights.properties.ConnectionString
    acrLoginServer: containerRegistry.outputs.loginServer
    managedIdentityId: managedIdentity.id
    sqlConnectionString: 'Server=tcp:${sqlDatabase.outputs.serverFqdn},1433;Initial Catalog=${sqlDatabase.outputs.databaseName};User ID=${sqlAdminUsername};Password=${sqlAdminPassword};Encrypt=true;TrustServerCertificate=false;Connection Timeout=30;'
  }
  dependsOn: [
    acrPullRole
  ]
}

// Container Apps Environment Private DNS Zone (for internal access)
module dnsZoneCae 'modules/privateDnsZone.bicep' = {
  name: 'deploy-dns-cae'
  params: {
    zoneName: containerApps.outputs.defaultDomain
    vnetLinks: [
      { name: 'link-hub', vnetId: vnetHub.outputs.id }
      { name: 'link-spoke1', vnetId: vnetSpoke1.outputs.id }
      { name: 'link-spoke2', vnetId: vnetSpoke2.outputs.id }
    ]
    aRecords: [
      { name: '*', ipv4Address: containerApps.outputs.staticIp }
    ]
  }
}

// ============================================================
// VNet Peerings (Hub <-> Spokes)
// ============================================================

// Hub -> Spoke1
resource peerHubToSpoke1 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  name: '${prefix}-vnet-hub/peer-to-spoke1'
  properties: {
    remoteVirtualNetwork: {
      id: vnetSpoke1.outputs.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}

// Spoke1 -> Hub
resource peerSpoke1ToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  name: '${prefix}-vnet-spoke1/peer-to-hub'
  properties: {
    remoteVirtualNetwork: {
      id: vnetHub.outputs.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
  dependsOn: [
    peerHubToSpoke1
  ]
}

// Hub -> Spoke2 (serialized after Hub->Spoke1 to avoid concurrent VNet modifications)
resource peerHubToSpoke2 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  name: '${prefix}-vnet-hub/peer-to-spoke2'
  properties: {
    remoteVirtualNetwork: {
      id: vnetSpoke2.outputs.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
  dependsOn: [
    peerHubToSpoke1
  ]
}

// Spoke2 -> Hub
resource peerSpoke2ToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  name: '${prefix}-vnet-spoke2/peer-to-hub'
  properties: {
    remoteVirtualNetwork: {
      id: vnetHub.outputs.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
  dependsOn: [
    peerHubToSpoke2
  ]
}

// ============================================================
// Azure Bastion (Developer SKU)
// ============================================================
resource bastionHub 'Microsoft.Network/bastionHosts@2024-01-01' = {
  name: '${prefix}-bastion-hub'
  location: location
  sku: {
    name: 'Developer'
  }
  properties: {
    virtualNetwork: {
      id: vnetHub.outputs.id
    }
  }
}

resource bastionSpoke2 'Microsoft.Network/bastionHosts@2024-01-01' = {
  name: '${prefix}-bastion-spoke2'
  location: location
  sku: {
    name: 'Developer'
  }
  properties: {
    virtualNetwork: {
      id: vnetSpoke2.outputs.id
    }
  }
}

// ============================================================
// VMs (Hub, Spoke2 - with Azure Monitor Agent + DCR)
// ============================================================
module vmHub 'modules/vm.bicep' = {
  name: 'deploy-vm-hub'
  params: {
    name: '${prefix}-vm-hub'
    location: location
    subnetId: vnetHub.outputs.subnets[1].id // sn-default
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    logAnalyticsWorkspaceId: logAnalytics.id
    dcrId: dcr.id
  }
}

module vmSpoke2 'modules/vm.bicep' = {
  name: 'deploy-vm-spoke2'
  params: {
    name: '${prefix}-vm-spoke2'
    location: location
    subnetId: vnetSpoke2.outputs.subnets[0].id // sn-default
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    logAnalyticsWorkspaceId: logAnalytics.id
    dcrId: dcr.id
  }
}

// ============================================================
// Outputs
// ============================================================

// --- Action Group & Alert Rules ---
module actionGroup 'modules/actionGroup.bicep' = {
  name: 'deploy-action-group'
  params: {
    name: '${prefix}-ag-sre'
    emailAddress: notificationEmail
  }
}

module alertRules 'modules/alertRules.bicep' = {
  name: 'deploy-alert-rules'
  params: {
    location: location
    prefix: prefix
    actionGroupId: actionGroup.outputs.id
    logAnalyticsWorkspaceId: logAnalytics.id
    appInsightsId: appInsights.id
    sqlDatabaseId: sqlDatabase.outputs.databaseId
    containerAppId: containerApps.outputs.appId
  }
}

output logAnalyticsWorkspaceId string = logAnalytics.id
output logAnalyticsWorkspaceName string = logAnalytics.name
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output firewallPrivateIp string = azureFirewall.outputs.privateIp
output firewallPublicIp string = azureFirewall.outputs.publicIp
output acrLoginServer string = containerRegistry.outputs.loginServer
output sqlServerFqdn string = sqlDatabase.outputs.serverFqdn
output containerAppFqdn string = containerApps.outputs.appFqdn
output containerAppStaticIp string = containerApps.outputs.staticIp
output vmHubPrivateIp string = vmHub.outputs.privateIp
output vmSpoke2PrivateIp string = vmSpoke2.outputs.privateIp
