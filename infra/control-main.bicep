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

@description('Identifier of the fault environment controlled by this application')
param faultEnvironmentId string

@description('Single public IPv4 address allowed to access the Control App. Leave empty to require VNet access.')
param allowedSourceIpAddress string = ''

@description('Existing fault state storage account name')
param storageAccountName string

@description('Existing Hub virtual network resource ID')
param virtualNetworkId string

@description('Existing delegated subnet resource ID for the Control Container Apps Environment')
param infrastructureSubnetId string

var activityTableName = 'ActivityEvents'
var faultStateTableName = 'FaultState'
var auditTableName = 'AuditLog'

module faultControl 'modules/faultControl.bicep' = {
  params: {
    activityTableName: activityTableName
    auditTableName: auditTableName
    allowedSourceIpAddress: allowedSourceIpAddress
    containerImage: containerImage
    faultEnvironmentId: faultEnvironmentId
    faultStateTableName: faultStateTableName
    infrastructureSubnetId: infrastructureSubnetId
    location: location
    prefix: prefix
    storageAccountName: storageAccountName
    targetPort: targetPort
    virtualNetworkId: virtualNetworkId
  }
}

output containerAppFqdn string = faultControl.outputs.containerAppFqdn
output containerAppId string = faultControl.outputs.containerAppId
output containerAppsDefaultDomain string = faultControl.outputs.defaultDomain
output containerAppsStaticIp string = faultControl.outputs.staticIp
output isPubliclyAccessible bool = faultControl.outputs.isPubliclyAccessible
output managedEnvironmentId string = faultControl.outputs.managedEnvironmentId
output managedIdentityId string = faultControl.outputs.managedIdentityId
output registryId string = faultControl.outputs.registryId
output registryLoginServer string = faultControl.outputs.registryLoginServer
output virtualNetworkId string = faultControl.outputs.virtualNetworkId
