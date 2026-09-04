using './control-main.bicep'

param prefix = 'srectrl'
param containerImage = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
param targetPort = 80
param allowedSourceIpAddress = readEnvironmentVariable('SRE_ALLOWED_SOURCE_IP', '')
param faultEnvironmentId = 'replace-with-target-environment-resource-id'
param storageAccountName = readEnvironmentVariable('SRE_FAULT_STORAGE_ACCOUNT')
param virtualNetworkId = readEnvironmentVariable('SRE_HUB_VNET_ID')
param infrastructureSubnetId = readEnvironmentVariable('SRE_CONTROL_INFRASTRUCTURE_SUBNET_ID')
