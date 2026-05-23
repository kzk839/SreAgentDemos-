using './main.bicep'

param prefix = 'sre-demo'
param adminUsername = readEnvironmentVariable('SRE_ADMIN_USERNAME', 'azureadmin')
param adminPassword = readEnvironmentVariable('SRE_ADMIN_PASSWORD')
param vmSize = 'Standard_B2s_v2'
param sqlAdminUsername = 'sqladmin'
param sqlAdminPassword = readEnvironmentVariable('SRE_SQL_PASSWORD')
param notificationEmail = readEnvironmentVariable('SRE_NOTIFICATION_EMAIL')
