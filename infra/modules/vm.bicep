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

@description('Attach and initialize a 4 GiB fault-injection data disk at LUN 0')
param enableFaultDataDisk bool = false

var faultDiskInitializationScript = '''
$ErrorActionPreference = 'Stop'

trap {
  Write-Error $_
  exit 1
}

$expectedSizeBytes = [int64]4GB
$lunZeroDisks = @(Get-Disk | Where-Object { $_.Location -match '\bLUN\s*0\b' })
$eligibleDisks = @($lunZeroDisks | Where-Object { -not $_.IsBoot -and -not $_.IsSystem })

if ($eligibleDisks.Count -ne 1) {
  throw "Expected exactly one non-boot, non-system disk at LUN 0; found $($eligibleDisks.Count)."
}

$disk = $eligibleDisks[0]
if ([int64]$disk.Size -ne $expectedSizeBytes) {
  throw "LUN 0 disk size mismatch. Expected $expectedSizeBytes bytes; found $($disk.Size) bytes."
}

if ($disk.PartitionStyle -ne 'RAW') {
  if ($disk.PartitionStyle -ne 'GPT') {
    throw "Existing LUN 0 disk uses unexpected partition style $($disk.PartitionStyle); no changes were made."
  }

  $dataPartitions = @(Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -eq 'Basic' })
  if ($dataPartitions.Count -ne 1 -or $dataPartitions[0].DriveLetter -ne 'F') {
    throw 'Existing LUN 0 disk is not the expected single F: data partition; no changes were made.'
  }

  $volume = Get-Volume -DriveLetter F -ErrorAction Stop
  if ($volume.FileSystem -ne 'NTFS' -or $volume.FileSystemLabel -ne 'SREFAULT') {
    throw 'Existing F: volume does not match NTFS/SREFAULT; no changes were made.'
  }

  Write-Output 'Fault disk is already initialized as GPT/NTFS F: with label SREFAULT.'
  exit 0
}

if (Get-Volume -DriveLetter F -ErrorAction SilentlyContinue) {
  throw 'Drive letter F: is already in use; the RAW disk was not initialized.'
}

if ($disk.IsOffline) {
  Set-Disk -Number $disk.Number -IsOffline $false
}
if ($disk.IsReadOnly) {
  Set-Disk -Number $disk.Number -IsReadOnly $false
}

$partition = Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru |
  New-Partition -UseMaximumSize -DriveLetter F
$partition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'SREFAULT' -Confirm:$false -Force
Write-Output 'Initialized LUN 0 as GPT/NTFS F: with label SREFAULT.'
'''
var faultDiskInitializationCommand = 'powershell.exe -NoLogo -NonInteractive -ExecutionPolicy Bypass -Command "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\'${base64(faultDiskInitializationScript)}\')) | Invoke-Expression"'

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
      dataDisks: enableFaultDataDisk ? [
        {
          name: '${name}-fault-data'
          lun: 0
          createOption: 'Empty'
          diskSizeGB: 4
          managedDisk: {
            storageAccountType: 'StandardSSD_LRS'
          }
        }
      ] : []
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

resource faultDiskInitializationExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = if (enableFaultDataDisk) {
  parent: vm
  name: 'InitializeFaultDataDisk'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      commandToExecute: faultDiskInitializationCommand
    }
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
