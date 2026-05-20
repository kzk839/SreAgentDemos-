@description('Action group name')
param name string

@description('Azure region')
param location string = 'global'

@description('Action group short name (max 12 chars)')
@maxLength(12)
param shortName string = 'SREAlerts'

@description('Notification email address')
param emailAddress string

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: name
  location: location
  properties: {
    enabled: true
    groupShortName: shortName
    emailReceivers: [
      {
        name: 'SRE-Admin'
        emailAddress: emailAddress
        useCommonAlertSchema: true
      }
    ]
  }
}

output id string = actionGroup.id
output name string = actionGroup.name
