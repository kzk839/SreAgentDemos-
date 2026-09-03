targetScope = 'resourceGroup'

@description('Azure region for the isolated control plane')
param location string = resourceGroup().location

@minLength(2)
@maxLength(10)
@description('Lowercase alphanumeric resource name prefix')
param prefix string = 'srectrl'

@description('Control App container image')
param containerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@minValue(1)
@maxValue(65535)
@description('Control App container target port')
param targetPort int = 80

@description('Microsoft Entra application client ID used by Container Apps built-in authentication')
param entraClientId string

@description('Microsoft Entra OpenID Connect issuer URL')
param entraIssuer string

@description('Identifier of the fault environment controlled by this application')
param faultEnvironmentId string

@description('Control plane virtual network address space')
param vnetAddressPrefix string = '10.4.0.0/16'

@description('Container Apps infrastructure subnet address prefix')
param infrastructureSubnetPrefix string = '10.4.0.0/23'

@description('Private endpoint subnet address prefix')
param privateEndpointSubnetPrefix string = '10.4.2.0/24'

var activityTableName = 'ActivityEvents'
var faultStateTableName = 'FaultState'
var auditTableName = 'AuditLog'

module faultState 'modules/faultState.bicep' = {
  params: {
    activityTableName: activityTableName
    auditTableName: auditTableName
    faultStateTableName: faultStateTableName
    location: location
    namePrefix: prefix
  }
}

module faultControl 'modules/faultControl.bicep' = {
  params: {
    activityTableName: activityTableName
    auditTableName: auditTableName
    containerImage: containerImage
    entraClientId: entraClientId
    entraIssuer: entraIssuer
    faultEnvironmentId: faultEnvironmentId
    faultStateTableName: faultStateTableName
    infrastructureSubnetPrefix: infrastructureSubnetPrefix
    location: location
    prefix: prefix
    privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
    storageAccountName: faultState.outputs.storageAccountName
    targetPort: targetPort
    vnetAddressPrefix: vnetAddressPrefix
  }
}

output activityTableId string = faultState.outputs.activityTableId
output auditTableId string = faultState.outputs.auditTableId
output containerAppFqdn string = faultControl.outputs.containerAppFqdn
output containerAppId string = faultControl.outputs.containerAppId
output faultStateTableId string = faultState.outputs.faultStateTableId
output managedEnvironmentId string = faultControl.outputs.managedEnvironmentId
output managedIdentityId string = faultControl.outputs.managedIdentityId
output registryId string = faultControl.outputs.registryId
output registryLoginServer string = faultControl.outputs.registryLoginServer
output storageAccountId string = faultState.outputs.storageAccountId
output storageTableEndpoint string = faultState.outputs.tableEndpoint
output tableServiceId string = faultState.outputs.tableServiceId
output virtualNetworkId string = faultControl.outputs.virtualNetworkId
