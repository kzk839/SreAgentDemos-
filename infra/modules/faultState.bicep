targetScope = 'resourceGroup'

@description('Azure region for the fault state storage account')
param location string

@minLength(2)
@maxLength(10)
@description('Lowercase alphanumeric prefix used to create a globally unique storage account name')
param namePrefix string

@description('Activity event table name')
param activityTableName string = 'ActivityEvents'

@description('Fault state table name')
param faultStateTableName string = 'FaultState'

@description('Audit log table name')
param auditTableName string = 'AuditLog'

var storageAccountName = take('${toLower(replace(namePrefix, '-', ''))}st${uniqueString(subscription().id, resourceGroup().id)}', 24)

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
    }
  }
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {}
}

resource activityTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableService
  name: activityTableName
  properties: {}
}

resource faultStateTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableService
  name: faultStateTableName
  properties: {}
}

resource auditTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableService
  name: auditTableName
  properties: {}
}

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
output tableEndpoint string = storageAccount.properties.primaryEndpoints.table
output tableServiceId string = tableService.id
output activityTableId string = activityTable.id
output faultStateTableId string = faultStateTable.id
output auditTableId string = auditTable.id
