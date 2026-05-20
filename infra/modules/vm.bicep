@description('VM name')
param name string

@description('Azure region')
param location string

@description('Subnet resource ID for the VM NIC')
param subnetId string

@description('VM admin username')
param adminUsername string

@secure()
@description('VM admin password')
param adminPassword string

@description('VM size')
param vmSize string = 'Standard_B2s'

@description('Log Analytics workspace ID for Azure Monitor Agent')
param logAnalyticsWorkspaceId string = ''

@description('Data Collection Rule ID')
param dcrId string = ''

resource nic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: '${name}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: name
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: take(replace(name, '-', ''), 15)
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource amaExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = if (!empty(logAnalyticsWorkspaceId)) {
  parent: vm
  name: 'AzureMonitorWindowsAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

resource dcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = if (!empty(dcrId)) {
  name: '${name}-dcra'
  scope: vm
  properties: {
    dataCollectionRuleId: dcrId
  }
}

output vmId string = vm.id
output vmName string = vm.name
output privateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
