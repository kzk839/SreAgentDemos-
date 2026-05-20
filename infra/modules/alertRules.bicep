// ============================================================
// SRE Demo - Alert Rules
// Infra (VM), App (Container Apps / App Insights), DB (SQL)
// ============================================================

@description('Azure region')
param location string

@description('Resource name prefix')
param prefix string

@description('Action Group resource ID')
param actionGroupId string

@description('Log Analytics Workspace resource ID')
param logAnalyticsWorkspaceId string

@description('Application Insights resource ID')
param appInsightsId string

@description('Azure SQL Database resource ID')
param sqlDatabaseId string

@description('Container App resource ID')
param containerAppId string

// ============================================================
// VM Alerts (Scheduled Query Rules on Log Analytics)
// ============================================================

// VM CPU > 90% for 5 minutes
resource alertVmCpu 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${prefix}-alert-vm-cpu-high'
  location: location
  properties: {
    displayName: 'VM CPU > 90%'
    description: 'Fires when any VM CPU exceeds 90% averaged over 5 minutes'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    criteria: {
      allOf: [
        {
          query: '''
            Perf
            | where ObjectName == "Processor" and CounterName == "% Processor Time" and InstanceName == "_Total"
            | summarize AvgCpu = avg(CounterValue) by Computer, bin(TimeGenerated, 5m)
            | where AvgCpu > 90
          '''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupId
      ]
    }
  }
}

// VM Available Memory < 500 MB
resource alertVmMemory 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${prefix}-alert-vm-memory-low'
  location: location
  properties: {
    displayName: 'VM Available Memory < 500MB'
    description: 'Fires when any VM available memory drops below 500 MB'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    criteria: {
      allOf: [
        {
          query: '''
            Perf
            | where ObjectName == "Memory" and CounterName == "Available MBytes"
            | summarize AvgMem = avg(CounterValue) by Computer, bin(TimeGenerated, 5m)
            | where AvgMem < 500
          '''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupId
      ]
    }
  }
}

// VM Disk Free Space < 10%
resource alertVmDisk 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${prefix}-alert-vm-disk-low'
  location: location
  properties: {
    displayName: 'VM Disk Free Space < 10%'
    description: 'Fires when any VM disk free space drops below 10%'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    criteria: {
      allOf: [
        {
          query: '''
            Perf
            | where ObjectName == "LogicalDisk" and CounterName == "% Free Space" and InstanceName == "_Total"
            | summarize AvgFree = avg(CounterValue) by Computer, bin(TimeGenerated, 5m)
            | where AvgFree < 10
          '''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupId
      ]
    }
  }
}

// ============================================================
// SQL Database Alerts (Metric Alerts)
// ============================================================

// SQL DTU Percentage > 90%
resource alertSqlDtu 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${prefix}-alert-sql-dtu-high'
  location: 'global'
  properties: {
    description: 'Fires when SQL Database DTU consumption exceeds 90%'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [
      sqlDatabaseId
    ]
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'DtuPercentageHigh'
          metricName: 'dtu_consumption_percent'
          metricNamespace: 'Microsoft.Sql/servers/databases'
          operator: 'GreaterThan'
          threshold: 90
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

// SQL Deadlocks > 0
resource alertSqlDeadlock 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${prefix}-alert-sql-deadlock'
  location: 'global'
  properties: {
    description: 'Fires when SQL Database detects a deadlock'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [
      sqlDatabaseId
    ]
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'DeadlockDetected'
          metricName: 'deadlock'
          metricNamespace: 'Microsoft.Sql/servers/databases'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

// SQL Failed Connections > 5
resource alertSqlConnFail 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${prefix}-alert-sql-conn-failed'
  location: 'global'
  properties: {
    description: 'Fires when SQL Database failed connections exceed 5 in 5 minutes'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [
      sqlDatabaseId
    ]
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'ConnectionFailedHigh'
          metricName: 'connection_failed'
          metricNamespace: 'Microsoft.Sql/servers/databases'
          operator: 'GreaterThan'
          threshold: 5
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

// ============================================================
// Application Alerts (App Insights Metric Alerts)
// ============================================================

// Response Time > 5 seconds
resource alertAppResponseTime 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${prefix}-alert-app-slow-response'
  location: 'global'
  properties: {
    description: 'Fires when average server response time exceeds 5 seconds'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [
      appInsightsId
    ]
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'SlowResponse'
          metricName: 'requests/duration'
          metricNamespace: 'microsoft.insights/components'
          operator: 'GreaterThan'
          threshold: 5000
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

// Failed Requests > 10%
resource alertAppFailedRequests 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${prefix}-alert-app-failed-requests'
  location: 'global'
  properties: {
    description: 'Fires when failed request count exceeds 10 in 5 minutes'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [
      appInsightsId
    ]
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighFailureRate'
          metricName: 'requests/failed'
          metricNamespace: 'microsoft.insights/components'
          operator: 'GreaterThan'
          threshold: 10
          timeAggregation: 'Count'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

// Server Exceptions > 0
resource alertAppExceptions 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${prefix}-alert-app-exceptions'
  location: 'global'
  properties: {
    description: 'Fires when server exceptions are detected'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [
      appInsightsId
    ]
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'ExceptionsDetected'
          metricName: 'exceptions/server'
          metricNamespace: 'microsoft.insights/components'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Count'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

// ============================================================
// Container App Alerts (Metric Alerts)
// ============================================================

// Container App Restart Count > 0
resource alertCaRestarts 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${prefix}-alert-ca-restarts'
  location: 'global'
  properties: {
    description: 'Fires when Container App restarts are detected'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [
      containerAppId
    ]
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'RestartDetected'
          metricName: 'RestartCount'
          metricNamespace: 'microsoft.app/containerapps'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Maximum'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

// Container App Replica Count = 0 (all replicas down)
resource alertCaReplicasDown 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${prefix}-alert-ca-replicas-down'
  location: 'global'
  properties: {
    description: 'Fires when Container App has zero running replicas'
    severity: 0
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [
      containerAppId
    ]
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'NoReplicas'
          metricName: 'Replicas'
          metricNamespace: 'microsoft.app/containerapps'
          operator: 'LessThanOrEqual'
          threshold: 0
          timeAggregation: 'Maximum'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}
