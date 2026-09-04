targetScope = 'resourceGroup'

@description('Azure region for the isolated control plane')
param location string

@minLength(2)
@maxLength(20)
@description('Resource name prefix')
param prefix string

@description('Existing virtual network resource ID containing the Control plane subnets')
param virtualNetworkId string

@description('Existing delegated subnet resource ID for the Control Container Apps Environment')
param infrastructureSubnetId string

@description('Control App container image; replace the placeholder image after publishing to the dedicated registry')
param containerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@minValue(1)
@maxValue(65535)
@description('Control App container target port')
param targetPort int = 80

@description('Identifier of the fault environment controlled by this application')
param faultEnvironmentId string

@description('Single public IPv4 address allowed to access the Control App. Leave empty to keep the environment internal.')
param allowedSourceIpAddress string = ''

@description('Existing fault state storage account name')
param storageAccountName string

@description('Activity event table name')
param activityTableName string = 'ActivityEvents'

@description('Fault state table name')
param faultStateTableName string = 'FaultState'

@description('Audit log table name')
param auditTableName string = 'AuditLog'

var controlIdentityName = '${prefix}-id'
var registryName = take('${toLower(replace(prefix, '-', ''))}acr${uniqueString(subscription().id, resourceGroup().id)}', 50)
var acrPullRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var tableDataContributorRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')

resource controlIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: controlIdentityName
  location: location
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: registryName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, controlIdentity.id, acrPullRoleDefinitionId)
  scope: registry
  properties: {
    principalId: controlIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleDefinitionId
  }
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-law'
  location: location
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${prefix}-cae'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: infrastructureSubnetId
      internal: empty(allowedSourceIpAddress)
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource activityTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' existing = {
  parent: tableService
  name: activityTableName
}

resource faultStateTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' existing = {
  parent: tableService
  name: faultStateTableName
}

resource auditTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' existing = {
  parent: tableService
  name: auditTableName
}

resource activityTableRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(activityTable.id, controlIdentity.id, tableDataContributorRoleDefinitionId)
  scope: activityTable
  properties: {
    principalId: controlIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: tableDataContributorRoleDefinitionId
  }
}

resource faultStateTableRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(faultStateTable.id, controlIdentity.id, tableDataContributorRoleDefinitionId)
  scope: faultStateTable
  properties: {
    principalId: controlIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: tableDataContributorRoleDefinitionId
  }
}

resource auditTableRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(auditTable.id, controlIdentity.id, tableDataContributorRoleDefinitionId)
  scope: auditTable
  properties: {
    principalId: controlIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: tableDataContributorRoleDefinitionId
  }
}

module controlCaePrivateDns 'privateDnsZone.bicep' = if (empty(allowedSourceIpAddress)) {
  name: 'deploy-control-cae-dns'
  params: {
    zoneName: managedEnvironment.properties.defaultDomain
    vnetLinks: [
      { name: '${prefix}-cae-link', vnetId: virtualNetworkId }
    ]
    aRecords: [
      { name: '*', ipv4Address: managedEnvironment.properties.staticIp }
    ]
  }
}

resource controlApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${prefix}-app'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${controlIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        allowInsecure: false
        external: true
        targetPort: targetPort
        transport: 'auto'
        ipSecurityRestrictions: empty(allowedSourceIpAddress)
          ? []
          : [
              {
                name: 'AllowDeploymentOperator'
                description: 'Allow the deployment-specified operator public IPv4 address'
                ipAddressRange: '${allowedSourceIpAddress}/32'
                action: 'Allow'
              }
            ]
      }
      registries: [
        {
          identity: controlIdentity.id
          server: registry.properties.loginServer
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'control-app'
          image: containerImage
          env: [
            {
              name: 'AZURE_STORAGE_TABLE_ENDPOINT'
              value: storageAccount.properties.primaryEndpoints.table
            }
            {
              name: 'ACTIVITY_TABLE_NAME'
              value: activityTableName
            }
            {
              name: 'FAULT_STATE_TABLE_NAME'
              value: faultStateTableName
            }
            {
              name: 'AUDIT_TABLE_NAME'
              value: auditTableName
            }
            {
              name: 'FAULT_ENVIRONMENT_ID'
              value: faultEnvironmentId
            }
          ]
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
        }
      ]
      scale: {
        maxReplicas: 3
        minReplicas: 1
      }
    }
  }
  dependsOn: [
    acrPullRoleAssignment
    activityTableRoleAssignment
    faultStateTableRoleAssignment
    auditTableRoleAssignment
    controlCaePrivateDns
  ]
}

output containerAppId string = controlApp.id
output containerAppFqdn string = controlApp.properties.configuration.ingress.fqdn
output defaultDomain string = managedEnvironment.properties.defaultDomain
output staticIp string = managedEnvironment.properties.staticIp
output managedEnvironmentId string = managedEnvironment.id
output managedIdentityId string = controlIdentity.id
output registryId string = registry.id
output registryLoginServer string = registry.properties.loginServer
output virtualNetworkId string = virtualNetworkId
output isPubliclyAccessible bool = !empty(allowedSourceIpAddress)
