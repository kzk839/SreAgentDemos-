'use strict';

const { createActivityStore } = require('./activity-store');
const { createApp } = require('./app');
const { createAuditStore } = require('./audit-store');
const { createFaultController } = require('./fault-controller');
const { createTableClients } = require('./table-clients');

function start() {
  const clients = createTableClients({ endpoint: process.env.TABLE_ENDPOINT });
  const activityStore = createActivityStore({ tableClient: clients.activity });
  const auditStore = createAuditStore({ tableClient: clients.audit });
  const faultController = createFaultController({ tableClient: clients.faults, auditStore, environmentId: process.env.ENVIRONMENT_ID || 'default' });
  const app = createApp({
    activityStore,
    auditStore,
    faultController,
    authDisabled: process.env.AUTH_DISABLED === 'true',
    mutationsEnabled: process.env.ENABLE_FAULT_INJECTION === 'true',
  });
  const port = Number(process.env.PORT) || 3000;
  app.listen(port, () => console.log(`Fault Control App listening on port ${port}`));
}

if (require.main === module) start();

module.exports = { start };