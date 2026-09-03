@description('Container Apps Environment name')
param environmentName string

@description('Container App name')
param appName string

@description('Azure region')
param location string

@description('Infrastructure subnet ID (min /23, delegated to Microsoft.App/environments)')
param infrastructureSubnetId string

@description('Log Analytics workspace customer ID')
param logAnalyticsCustomerId string

@secure()
@description('Log Analytics workspace shared key')
param logAnalyticsSharedKey string

@description('Application Insights connection string')
param appInsightsConnectionString string = ''

@description('ACR login server')
param acrLoginServer string = ''

@description('User Assigned Managed Identity resource ID')
param managedIdentityId string = ''

@description('Container image (default: hello-world for initial deployment)')
param containerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@secure()
@description('SQL connection string')
param sqlConnectionString string = ''

@description('Log Analytics Workspace resource ID for diagnostic settings')
param logAnalyticsWorkspaceId string = ''

@description('Azure Storage Table service endpoint')
param tableEndpoint string = ''

@description('Identifier used to partition fault state for this environment')
param faultEnvironmentId string = ''

@description('Enable application fault injection behavior')
param enableFaultInjection bool = false

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: infrastructureSubnetId
      internal: true
    }
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: logAnalyticsSharedKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  identity: !empty(managedIdentityId)
    ? {
        type: 'UserAssigned'
        userAssignedIdentities: {
          '${managedIdentityId}': {}
        }
      }
    : { type: 'None' }
  properties: {
    managedEnvironmentId: environment.id
    configuration: {
      secrets: !empty(sqlConnectionString)
        ? [
            {
              name: 'sql-connection-string'
              value: sqlConnectionString
            }
          ]
        : []
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
      }
      registries: !empty(acrLoginServer) && !empty(managedIdentityId)
        ? [
            {
              server: acrLoginServer
              identity: managedIdentityId
            }
          ]
        : []
    }
    template: {
      containers: [
        {
          name: 'main'
          image: containerImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: concat(
            [
              {
                name: 'AZURE_STORAGE_TABLE_ENDPOINT'
                value: tableEndpoint
              }
              {
                name: 'ACTIVITY_TABLE_NAME'
                value: 'ActivityEvents'
              }
              {
                name: 'FAULT_STATE_TABLE_NAME'
                value: 'FaultState'
              }
              {
                name: 'FAULT_ENVIRONMENT_ID'
                value: faultEnvironmentId
              }
              {
                name: 'ENABLE_FAULT_INJECTION'
                value: string(enableFaultInjection)
              }
            ],
            !empty(appInsightsConnectionString)
              ? [
                  {
                    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
                    value: appInsightsConnectionString
                  }
                ]
              : [],
            !empty(sqlConnectionString)
              ? [
                  {
                    name: 'SQL_CONNECTION_STRING'
                    secretRef: 'sql-connection-string'
                  }
                ]
              : []
          )
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/health'
                port: 8080
              }
              initialDelaySeconds: 10
              periodSeconds: 30
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/ready'
                port: 8080
              }
              initialDelaySeconds: 5
              periodSeconds: 10
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

// Diagnostic settings for Container Apps Environment
resource environmentDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: '${environmentName}-diag'
  scope: environment
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'ContainerAppConsoleLogs'
        enabled: true
      }
      {
        category: 'ContainerAppSystemLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output environmentId string = environment.id
output environmentName string = environment.name
output defaultDomain string = environment.properties.defaultDomain
output staticIp string = environment.properties.staticIp
output appFqdn string = containerApp.properties.configuration.ingress.fqdn
output appId string = containerApp.id
