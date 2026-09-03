using './main.bicep'

param prefix = 'sre-demo'
param adminUsername = readEnvironmentVariable('SRE_ADMIN_USERNAME', 'azureadmin')
param adminPassword = readEnvironmentVariable('SRE_ADMIN_PASSWORD')
param vmSize = 'Standard_B2s_v2'
param sqlAdminUsername = 'sqladmin'
param sqlAdminPassword = readEnvironmentVariable('SRE_SQL_PASSWORD')
param sqlFaultRunnerPassword = readEnvironmentVariable('SRE_SQL_FAULT_RUNNER_PASSWORD')
param notificationEmail = readEnvironmentVariable('SRE_NOTIFICATION_EMAIL')
param controlResourceGroupName = readEnvironmentVariable('SRE_CONTROL_RESOURCE_GROUP', '')
param faultStorageAccountName = readEnvironmentVariable('SRE_FAULT_STORAGE_ACCOUNT', '')
param faultEnvironmentId = readEnvironmentVariable('SRE_FAULT_ENVIRONMENT_ID', '')
param demoAllowedSourceIp = readEnvironmentVariable('SRE_DEMO_ALLOWED_SOURCE_IP', '')
