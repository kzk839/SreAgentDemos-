using './control-main.bicep'

param prefix = 'srectrl'
param containerImage = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
param targetPort = 80
param entraClientId = '00000000-0000-0000-0000-000000000000'
param entraIssuer = 'https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0'
param faultEnvironmentId = 'replace-with-target-environment-resource-id'
param vnetAddressPrefix = '10.4.0.0/16'
param infrastructureSubnetPrefix = '10.4.0.0/23'
param privateEndpointSubnetPrefix = '10.4.2.0/24'
