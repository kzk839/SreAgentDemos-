// ============================================================
// Azure SRE Agent - Standalone deployment
// ============================================================
// Deploys SRE Agent + Managed Identity.
// DataConnectors, Knowledge Base, ポータル設定は deploy.ps1
// またはポータル (sre.azure.com) で実施。
//
// Usage:
//   az deployment group create \
//     --resource-group <sre-agent-rg> \
//     --template-file infra/sre-agent.bicep \
//     --parameters infra/sre-agent.bicepparam
//
// Prerequisites:
//   - Target RG must exist
//   - Caller must have Owner or Contributor+UAA on both RGs
//   - Microsoft.App provider must be registered
// ============================================================

targetScope = 'resourceGroup'

// ============================================================
// Parameters
// ============================================================
@description('Azure region for SRE Agent (must be eastus2, swedencentral, or australiaeast)')
@allowed(['eastus2', 'swedencentral', 'australiaeast'])
param location string = 'eastus2'

@description('SRE Agent name')
param agentName string = 'sre-demo-agent'

@description('Resource name prefix')
param prefix string = 'sre-demo'

@description('Resource Group ID of the infrastructure to monitor (e.g., /subscriptions/.../resourceGroups/rg-sre-demo6)')
param infraResourceGroupId string

@description('Application Insights App ID (for agent telemetry)')
param appInsightsAppId string

@description('Application Insights connection string')
@secure()
param appInsightsConnectionString string

@description('Action configuration mode')
@allowed(['Review', 'Autonomous', 'ReadOnly'])
param actionMode string = 'Autonomous'

// ============================================================
// Managed Identity (for SRE Agent to access Azure resources)
// ============================================================
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-id-sre-agent'
  location: location
}

// ============================================================
// SRE Agent
// ============================================================
resource agent 'Microsoft.App/agents@2025-05-01-preview' = {
  name: agentName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    actionConfiguration: {
      mode: actionMode
      accessLevel: 'High'
      identity: managedIdentity.id
    }
    defaultModel: {
      provider: 'Anthropic'
      name: 'Automatic'
    }
    knowledgeGraphConfiguration: {
      identity: managedIdentity.id
      managedResources: [
        infraResourceGroupId
      ]
    }
    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: appInsightsAppId
        connectionString: appInsightsConnectionString
      }
    }
    incidentManagementConfiguration: {
      type: 'AzMonitor'
    }
    upgradeChannel: 'Stable'
  }
}

// ============================================================
// RBAC - Infra RG への権限付与は deploy-sre-agent.ps1 で実施
// DataConnectors / Knowledge Base / サブエージェント / スケジュールタスク
// はポータル (sre.azure.com) で設定
// ============================================================

// ============================================================
// Outputs
// ============================================================
output agentName string = agent.name
output agentEndpoint string = agent.properties.agentEndpoint
output managedIdentityPrincipalId string = managedIdentity.properties.principalId
output managedIdentityClientId string = managedIdentity.properties.clientId
output agentResourceId string = agent.id
output portalUrl string = 'https://sre.azure.com/#/agent/${subscription().subscriptionId}/${resourceGroup().name}/${agent.name}'
