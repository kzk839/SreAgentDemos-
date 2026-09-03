targetScope = 'resourceGroup'

@description('Azure region for the isolated control plane')
param location string

@minLength(2)
@maxLength(20)
@description('Resource name prefix')
param prefix string

@description('Control plane virtual network address space')
param vnetAddressPrefix string = '10.4.0.0/16'

@description('Container Apps infrastructure subnet address prefix')
param infrastructureSubnetPrefix string = '10.4.0.0/23'

@description('Private endpoint subnet address prefix')
param privateEndpointSubnetPrefix string = '10.4.2.0/24'

@description('Control App container image; replace the placeholder image after publishing to the dedicated registry')
param containerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@minValue(1)
@maxValue(65535)
@description('Control App container target port')
param targetPort int = 80

@description('Microsoft Entra application client ID used by Container Apps built-in authentication')
param entraClientId string

@description('Microsoft Entra OpenID Connect issuer URL, for example https://login.microsoftonline.com/{tenant-id}/v2.0')
param entraIssuer string

@description('Identifier of the fault environment controlled by this application')
param faultEnvironmentId string

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

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: '${prefix}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
  }
}

resource infrastructureSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = {
  parent: virtualNetwork
  name: 'snet-aca-infrastructure'
  properties: {
    addressPrefix: infrastructureSubnetPrefix
    delegations: [
      {
        name: 'Microsoft.App.environments'
        properties: {
          serviceName: 'Microsoft.App/environments'
        }
      }
    ]
  }
}

resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = {
  parent: virtualNetwork
  name: 'snet-private-endpoints'
  properties: {
    addressPrefix: privateEndpointSubnetPrefix
    privateEndpointNetworkPolicies: 'Disabled'
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
      infrastructureSubnetId: infrastructureSubnet.id
      internal: false
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

resource tablePrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.table.${environment().suffixes.storage}'
  location: 'global'
}

resource tablePrivateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: tablePrivateDnsZone
  name: '${prefix}-table-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource tablePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: '${prefix}-table-pe'
  location: location
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'table'
        properties: {
          groupIds: [
            'table'
          ]
          privateLinkServiceId: storageAccount.id
        }
      }
    ]
    subnet: {
      id: privateEndpointSubnet.id
    }
  }
}

resource tablePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: tablePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'table'
        properties: {
          privateDnsZoneId: tablePrivateDnsZone.id
        }
      }
    ]
  }
  dependsOn: [
    tablePrivateDnsLink
  ]
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
            {
              name: 'AUTH_DISABLED'
              value: 'false'
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
    tablePrivateDnsZoneGroup
  ]
}

resource controlAppAuth 'Microsoft.App/containerApps/authConfigs@2024-03-01' = {
  parent: controlApp
  name: 'current'
  properties: {
    globalValidation: {
      redirectToProvider: 'azureActiveDirectory'
      unauthenticatedClientAction: 'RedirectToLoginPage'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: entraClientId
          openIdIssuer: entraIssuer
        }
      }
    }
    platform: {
      enabled: true
    }
  }
}

output containerAppId string = controlApp.id
output containerAppFqdn string = controlApp.properties.configuration.ingress.fqdn
output managedEnvironmentId string = managedEnvironment.id
output managedIdentityId string = controlIdentity.id
output registryId string = registry.id
output registryLoginServer string = registry.properties.loginServer
output virtualNetworkId string = virtualNetwork.id
