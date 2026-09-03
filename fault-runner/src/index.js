'use strict';

const { DefaultAzureCredential } = require('@azure/identity');
const { createExecutors } = require('./executors');
const { createReconciler } = require('./reconciler');
const { createFaultRunner } = require('./runner');
const { createStateStore } = require('./state-store');

const required = ['AZURE_STORAGE_TABLE_ENDPOINT', 'FAULT_ENVIRONMENT_ID'];
for (const name of required) {
  if (!process.env[name]) throw new Error(`${name} is required`);
}

const credential = new DefaultAzureCredential({ managedIdentityClientId: process.env.AZURE_CLIENT_ID });
const store = createStateStore({
  endpoint: process.env.AZURE_STORAGE_TABLE_ENDPOINT,
  tableName: process.env.FAULT_STATE_TABLE_NAME || 'FaultState',
  environmentId: process.env.FAULT_ENVIRONMENT_ID,
  credential,
});

async function main() {
  for (const name of ['AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'VM_NAME', 'SQL_CONNECTION_STRING', 'FIREWALL_POLICY_NAME', 'FIREWALL_RULE_COLLECTION_GROUP_NAME']) {
    if (!process.env[name]) throw new Error(`${name} is required`);
  }
  const runner = createFaultRunner({
    store,
    executors: createExecutors({
      credential,
      subscriptionId: process.env.AZURE_SUBSCRIPTION_ID,
      resourceGroupName: process.env.AZURE_RESOURCE_GROUP,
      vmName: process.env.VM_NAME,
      sqlConnectionString: process.env.SQL_CONNECTION_STRING,
      firewallPolicyName: process.env.FIREWALL_POLICY_NAME,
      ruleCollectionGroupName: process.env.FIREWALL_RULE_COLLECTION_GROUP_NAME,
    }),
  });
  if (process.env.RUN_MODE === 'reconcile') {
    await runner.runOnce();
    await createReconciler({ store }).runOnce();
    return;
  }

  const intervalMs = Math.max(5_000, Number(process.env.POLL_INTERVAL_MS) || 10_000);
  await runner.runContinuously(intervalMs);
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
