targetScope = 'resourceGroup'

@description('Existing fault storage account name')
param storageAccountName string

@description('Principal ID of the Demo user-assigned managed identity')
param principalId string

var tableDataContributorRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource activityTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' existing = {
  parent: tableService
  name: 'ActivityEvents'
}

resource faultStateTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' existing = {
  parent: tableService
  name: 'FaultState'
}

resource activityTableRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(activityTable.id, principalId, tableDataContributorRoleDefinitionId)
  scope: activityTable
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: tableDataContributorRoleDefinitionId
  }
}

resource faultStateTableRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(faultStateTable.id, principalId, tableDataContributorRoleDefinitionId)
  scope: faultStateTable
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: tableDataContributorRoleDefinitionId
  }
}
