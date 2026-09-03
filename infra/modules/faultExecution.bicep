@description('Azure region')
param location string

@description('Resource name prefix')
param prefix string

@description('Existing Container Apps managed environment resource ID')
param managedEnvironmentId string

@description('Fault Runner container image')
param containerImage string

@description('Azure Container Registry login server')
param acrLoginServer string

@description('Existing Azure Container Registry name')
param acrName string

@description('Azure Storage Table service endpoint')
param tableEndpoint string

@description('Existing fault state storage account name')
param storageAccountName string

@description('Fault state partition identifier')
param faultEnvironmentId string

@description('Azure subscription ID')
param subscriptionId string

@description('Infrastructure resource group name')
param resourceGroupName string

@description('Target VM name')
param vmName string

@description('Firewall Policy name')
param firewallPolicyName string

@description('Dedicated Firewall Policy rule collection group name')
param firewallRuleCollectionGroupName string

@secure()
@description('SQL connection string used only by the fixed SQL fault executors')
param sqlConnectionString string

var acrPullRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var tableStateRoleName = guid(resourceGroup().id, 'sre-fault-state-role')
var vmRunnerRoleName = guid(resourceGroup().id, 'sre-fault-vm-runner-role')
var networkRunnerRoleName = guid(resourceGroup().id, 'sre-fault-network-runner-role')

resource runnerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-id-fault-runner'
  location: location
}

resource reconcilerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-id-fault-reconciler'
  location: location
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource faultStateTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' existing = {
  parent: tableService
  name: 'FaultState'
}

resource targetVm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: vmName
}

resource targetFirewallPolicy 'Microsoft.Network/firewallPolicies@2024-01-01' existing = {
  name: firewallPolicyName
}

resource targetFaultRuleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-01-01' existing = {
  parent: targetFirewallPolicy
  name: firewallRuleCollectionGroupName
}

resource tableStateRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: tableStateRoleName
  properties: {
    roleName: '${prefix} Fault State Writer'
    description: 'Read and update existing fault state entities.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [{
      actions: []
      notActions: []
      dataActions: [
        'Microsoft.Storage/storageAccounts/tableServices/tables/entities/read'
        'Microsoft.Storage/storageAccounts/tableServices/tables/entities/write'
      ]
      notDataActions: []
    }]
  }
}

resource runnerTableAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(faultStateTable.id, runnerIdentity.id, tableStateRole.id)
  scope: faultStateTable
  properties: {
    principalId: runnerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: tableStateRole.id
  }
}

resource reconcilerTableAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(faultStateTable.id, reconcilerIdentity.id, tableStateRole.id)
  scope: faultStateTable
  properties: {
    principalId: reconcilerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: tableStateRole.id
  }
}

resource runnerAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, runnerIdentity.id, acrPullRoleDefinitionId)
  scope: registry
  properties: {
    principalId: runnerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleDefinitionId
  }
}

resource reconcilerAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, reconcilerIdentity.id, acrPullRoleDefinitionId)
  scope: registry
  properties: {
    principalId: reconcilerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleDefinitionId
  }
}

resource vmRunnerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: vmRunnerRoleName
  properties: {
    roleName: '${prefix} Fault VM Runner'
    description: 'Execute the fixed SRE demo VM fault catalog.'
    type: 'CustomRole'
    assignableScopes: [
      resourceGroup().id
    ]
    permissions: [
      {
        actions: [
          'Microsoft.Compute/virtualMachines/read'
          'Microsoft.Compute/virtualMachines/runCommand/action'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

resource networkRunnerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: networkRunnerRoleName
  properties: {
    roleName: '${prefix} Fault Network Runner'
    description: 'Update only the dedicated SRE demo firewall rule collection group.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [{
      actions: [
        'Microsoft.Network/firewallPolicies/ruleCollectionGroups/read'
        'Microsoft.Network/firewallPolicies/ruleCollectionGroups/write'
      ]
      notActions: []
      dataActions: []
      notDataActions: []
    }]
  }
}

resource runnerVmRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(targetVm.id, runnerIdentity.id, vmRunnerRole.id)
  scope: targetVm
  properties: {
    principalId: runnerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: vmRunnerRole.id
  }
}

resource reconcilerVmRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(targetVm.id, reconcilerIdentity.id, vmRunnerRole.id)
  scope: targetVm
  properties: {
    principalId: reconcilerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: vmRunnerRole.id
  }
}

resource runnerNetworkRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(targetFaultRuleCollectionGroup.id, runnerIdentity.id, networkRunnerRole.id)
  scope: targetFaultRuleCollectionGroup
  properties: {
    principalId: runnerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: networkRunnerRole.id
  }
}

resource reconcilerNetworkRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(targetFaultRuleCollectionGroup.id, reconcilerIdentity.id, networkRunnerRole.id)
  scope: targetFaultRuleCollectionGroup
  properties: {
    principalId: reconcilerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: networkRunnerRole.id
  }
}

resource runner 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${prefix}-fault-runner'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${runnerIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      registries: [
        {
          server: acrLoginServer
          identity: runnerIdentity.id
        }
      ]
      secrets: [
        {
          name: 'sql-connection-string'
          value: sqlConnectionString
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'runner'
          image: containerImage
          env: [
            { name: 'AZURE_CLIENT_ID', value: runnerIdentity.properties.clientId }
            { name: 'AZURE_STORAGE_TABLE_ENDPOINT', value: tableEndpoint }
            { name: 'FAULT_STATE_TABLE_NAME', value: 'FaultState' }
            { name: 'FAULT_ENVIRONMENT_ID', value: faultEnvironmentId }
            { name: 'AZURE_SUBSCRIPTION_ID', value: subscriptionId }
            { name: 'AZURE_RESOURCE_GROUP', value: resourceGroupName }
            { name: 'VM_NAME', value: vmName }
            { name: 'FIREWALL_POLICY_NAME', value: firewallPolicyName }
            { name: 'FIREWALL_RULE_COLLECTION_GROUP_NAME', value: firewallRuleCollectionGroupName }
            { name: 'SQL_CONNECTION_STRING', secretRef: 'sql-connection-string' }
            { name: 'POLL_INTERVAL_MS', value: '10000' }
          ]
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
  dependsOn: [
    runnerAcrPull
    runnerVmRoleAssignment
    runnerNetworkRoleAssignment
    runnerTableAccess
  ]
}

resource reconciler 'Microsoft.App/jobs@2024-03-01' = {
  name: '${prefix}-fault-reconciler'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${reconcilerIdentity.id}': {}
    }
  }
  properties: {
    environmentId: managedEnvironmentId
    configuration: {
      triggerType: 'Schedule'
      replicaRetryLimit: 1
      replicaTimeout: 120
      scheduleTriggerConfig: {
        cronExpression: '*/1 * * * *'
        parallelism: 1
        replicaCompletionCount: 1
      }
      registries: [
        {
          server: acrLoginServer
          identity: reconcilerIdentity.id
        }
      ]
      secrets: [
        {
          name: 'sql-connection-string'
          value: sqlConnectionString
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'reconciler'
          image: containerImage
          env: [
            { name: 'AZURE_CLIENT_ID', value: reconcilerIdentity.properties.clientId }
            { name: 'AZURE_STORAGE_TABLE_ENDPOINT', value: tableEndpoint }
            { name: 'FAULT_STATE_TABLE_NAME', value: 'FaultState' }
            { name: 'FAULT_ENVIRONMENT_ID', value: faultEnvironmentId }
            { name: 'AZURE_SUBSCRIPTION_ID', value: subscriptionId }
            { name: 'AZURE_RESOURCE_GROUP', value: resourceGroupName }
            { name: 'VM_NAME', value: vmName }
            { name: 'FIREWALL_POLICY_NAME', value: firewallPolicyName }
            { name: 'FIREWALL_RULE_COLLECTION_GROUP_NAME', value: firewallRuleCollectionGroupName }
            { name: 'SQL_CONNECTION_STRING', secretRef: 'sql-connection-string' }
            { name: 'RUN_MODE', value: 'reconcile' }
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
    }
  }
  dependsOn: [
    reconcilerAcrPull
    reconcilerTableAccess
    reconcilerVmRoleAssignment
    reconcilerNetworkRoleAssignment
  ]
}

output runnerId string = runner.id
output runnerIdentityPrincipalId string = runnerIdentity.properties.principalId
output reconcilerId string = reconciler.id
output reconcilerIdentityPrincipalId string = reconcilerIdentity.properties.principalId
