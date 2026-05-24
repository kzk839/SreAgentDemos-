using './sre-agent.bicep'

param location = 'eastus2'
param agentName = 'sre-demo-agent'
param prefix = 'sre-demo'
param actionMode = 'Autonomous'

// These values are populated by deploy.ps1 at deploy time
param infraResourceGroupId = readEnvironmentVariable('SRE_INFRA_RG_ID')
param appInsightsAppId = readEnvironmentVariable('SRE_APPI_APP_ID')
param appInsightsConnectionString = readEnvironmentVariable('SRE_APPI_CONNECTION_STRING')
