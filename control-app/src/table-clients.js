'use strict';

const { TableClient } = require('@azure/data-tables');
const { DefaultAzureCredential } = require('@azure/identity');

function createTableClients(options = {}) {
  const endpoint = options.endpoint;
  if (!endpoint) throw new Error('TABLE_ENDPOINT is required');
  const credential = options.credential || new DefaultAzureCredential();
  const client = tableName => new TableClient(endpoint, tableName, credential);
  return {
    activity: client(options.activityTableName || 'ActivityEvents'),
    faults: client(options.faultTableName || 'FaultState'),
    audit: client(options.auditTableName || 'FaultAudit'),
  };
}

module.exports = { createTableClients };