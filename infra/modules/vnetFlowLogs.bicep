// ============================================================
// VNet Flow Logs (deployed to NetworkWatcherRG)
// ============================================================

@description('Azure region')
param location string

@description('Network Watcher name (e.g. NetworkWatcher_southeastasia)')
param networkWatcherName string

@description('Array of VNets: [{name, id}]')
param vnets array

@description('Storage Account resource ID for flow log retention')
param storageAccountId string

@description('Log Analytics Workspace resource ID for Traffic Analytics')
param workspaceId string

@description('Flow log retention in days')
param retentionDays int = 7

resource networkWatcher 'Microsoft.Network/networkWatchers@2024-01-01' existing = {
  name: networkWatcherName
}

resource flowLogs 'Microsoft.Network/networkWatchers/flowLogs@2024-01-01' = [
  for vnet in vnets: {
    parent: networkWatcher
    name: 'sre-demo-flowlog-${vnet.name}'
    location: location
    properties: {
      targetResourceId: vnet.id
      storageId: storageAccountId
      enabled: true
      retentionPolicy: {
        enabled: true
        days: retentionDays
      }
      flowAnalyticsConfiguration: {
        networkWatcherFlowAnalyticsConfiguration: {
          enabled: true
          workspaceResourceId: workspaceId
          trafficAnalyticsInterval: 10
        }
      }
    }
  }
]
