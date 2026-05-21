// ============================================================
// Azure SRE Agent - Standalone deployment
// ============================================================
// Deploys SRE Agent + Managed Identity + RBAC + Connectors +
// Custom Agents + Scheduled Tasks.
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

@description('Log Analytics Workspace resource ID')
param logAnalyticsWorkspaceId string

@description('Application Insights resource ID')
param appInsightsResourceId string

@description('Application Insights App ID (for connector)')
param appInsightsAppId string

@description('Application Insights connection string')
@secure()
param appInsightsConnectionString string

@description('Action configuration mode')
@allowed(['Review', 'Autonomous', 'ReadOnly'])
param actionMode string = 'Autonomous'

// ============================================================
// Variables
// ============================================================
var networkExpertPrompt = loadTextContent('prompts/network-expert.md')
var appExpertPrompt = loadTextContent('prompts/app-expert.md')
var dbExpertPrompt = loadTextContent('prompts/db-expert.md')
var healthCheckPrompt = loadTextContent('prompts/health-check.md')
var commonPrompt = loadTextContent('prompts/common.md')

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
// (Bicep は SRE Agent RG スコープしか扱えないため)
// ============================================================

// ============================================================
// Connectors - Log Analytics
// ============================================================
resource connectorLaw 'Microsoft.App/agents/DataConnectors@2025-05-01-preview' = {
  parent: agent
  name: 'log-analytics'
  properties: {
    name: 'log-analytics'
    dataConnectorType: 'Kusto'
    dataSource: logAnalyticsWorkspaceId
    identity: 'system'
  }
}

// ============================================================
// Connectors - Application Insights
// ============================================================
resource connectorAppInsights 'Microsoft.App/agents/DataConnectors@2025-05-01-preview' = {
  parent: agent
  name: 'app-insights'
  properties: {
    name: 'app-insights'
    dataConnectorType: 'Kusto'
    dataSource: appInsightsResourceId
    identity: 'system'
  }
}

// ============================================================
// Common Prompts (global instructions for the agent)
// ============================================================
resource commonPromptResource 'Microsoft.App/agents/commonPrompts@2025-05-01-preview' = {
  parent: agent
  name: 'incident-response-workflow'
  properties: {
    value: base64(string({
      name: 'incident-response-workflow'
      description: 'Defines the overall incident response workflow: triage, investigate, mitigate, verify, report'
      content: commonPrompt
      enabled: true
    }))
  }
}

// ============================================================
// Custom Agents (subagents)
// ============================================================
resource subagentNetwork 'Microsoft.App/agents/subagents@2025-05-01-preview' = {
  parent: agent
  name: 'network-expert'
  properties: {
    value: base64(string({
      name: 'network-expert'
      system_prompt: networkExpertPrompt
      handoff_description: 'Handles networking, routing, firewall, VPN, NSG, and DNS troubleshooting in the hub-spoke environment'
      tools: ['azure_cli', 'execute_kusto_query']
      enable_skills: true
    }))
  }
}

resource subagentApp 'Microsoft.App/agents/subagents@2025-05-01-preview' = {
  parent: agent
  name: 'app-expert'
  properties: {
    value: base64(string({
      name: 'app-expert'
      system_prompt: appExpertPrompt
      handoff_description: 'Handles Container Apps, Application Insights, and application-level troubleshooting including performance, errors, and scaling'
      tools: ['azure_cli', 'execute_kusto_query']
      enable_skills: true
    }))
  }
}

resource subagentDb 'Microsoft.App/agents/subagents@2025-05-01-preview' = {
  parent: agent
  name: 'db-expert'
  properties: {
    value: base64(string({
      name: 'db-expert'
      system_prompt: dbExpertPrompt
      handoff_description: 'Handles Azure SQL Database troubleshooting including DTU issues, deadlocks, connection failures, and query performance'
      tools: ['azure_cli', 'execute_kusto_query']
      enable_skills: true
    }))
  }
}

// ============================================================
// Scheduled Tasks
// ============================================================
resource taskHealthCheck 'Microsoft.App/agents/scheduledTasks@2025-05-01-preview' = {
  parent: agent
  name: 'daily-health-check'
  properties: {
    value: base64(string({
      name: 'daily-health-check'
      description: 'Daily health check of all SRE Demo resources'
      instructions: healthCheckPrompt
      schedule: '0 0 * * *'
      enabled: true
      mode: 'Autonomous'
    }))
  }
}

// ============================================================
// Outputs
// ============================================================
output agentName string = agent.name
output agentEndpoint string = agent.properties.agentEndpoint
output managedIdentityPrincipalId string = managedIdentity.properties.principalId
output managedIdentityClientId string = managedIdentity.properties.clientId
output portalUrl string = 'https://sre.azure.com/#/agent/${subscription().subscriptionId}/${resourceGroup().name}/${agent.name}'
