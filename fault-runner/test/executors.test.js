'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createNetworkExecutor, createSqlExecutors, createVmExecutor } = require('../src/executors');

test('VM executor sends only the catalogued PowerShell and stop task commands', async () => {
  const calls = [];
  const computeClient = {
    virtualMachines: {
      beginRunCommandAndWait: async (...args) => calls.push(args),
    },
  };
  const executor = createVmExecutor({ computeClient, resourceGroupName: 'rg-demo', vmName: 'vm-hub', faultId: 'vm-cpu-high' });
  await executor.apply();
  await executor.revert();
  assert.equal(calls[0][0], 'rg-demo');
  assert.equal(calls[0][1], 'vm-hub');
  assert.match(calls[0][2].script[0], /SreFaultCpu/);
  assert.match(calls[1][2].script[0], /Unregister-ScheduledTask/);
});

test('network executor writes and clears only the dedicated fixed deny collection', async () => {
  const calls = [];
  const networkClient = {
    firewallPolicyRuleCollectionGroups: {
      beginCreateOrUpdateAndWait: async (...args) => calls.push(args),
    },
  };
  const executor = createNetworkExecutor({
    networkClient,
    resourceGroupName: 'rg-demo',
    firewallPolicyName: 'demo-policy',
    ruleCollectionGroupName: 'SreFaultRuleCollectionGroup',
  });
  await executor.apply();
  await executor.revert();
  assert.equal(calls[0][2], 'SreFaultRuleCollectionGroup');
  assert.equal(calls[0][3].ruleCollections[0].action.type, 'Deny');
  assert.deepEqual(calls[0][3].ruleCollections[0].rules[0].sourceAddresses, ['10.3.0.0/16']);
  assert.deepEqual(calls[1][3].ruleCollections, []);
});

test('network executor detects rule field drift', async () => {
  const networkClient = {
    firewallPolicyRuleCollectionGroups: {
      get: async () => ({
        priority: 100,
        ruleCollections: [{
          name: 'DenySpoke2ToSpoke1',
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection',
          priority: 100,
          action: { type: 'Deny' },
          rules: [{
            name: 'DenyCataloguedSpokeTraffic',
            ruleType: 'NetworkRule',
            sourceAddresses: ['10.3.0.0/16'],
            destinationAddresses: ['10.2.0.0/16'],
            destinationPorts: ['443'],
            ipProtocols: ['Any'],
          }],
        }],
      }),
    },
  };
  const executor = createNetworkExecutor({
    networkClient,
    resourceGroupName: 'rg-demo',
    firewallPolicyName: 'demo-policy',
    ruleCollectionGroupName: 'SreFaultRuleCollectionGroup',
  });
  assert.equal(await executor.verify(), false);
});

test('SQL executor retries connection after an initial failure', async () => {
  let attempts = 0;
  const connection = { request: () => ({ query: async () => ({}) }) };
  const sqlClient = {
    connect: async () => {
      attempts += 1;
      if (attempts === 1) throw new Error('temporary failure');
      return connection;
    },
  };
  const executor = createSqlExecutors('fixed-connection', sqlClient)['sql-high-load'];
  await assert.rejects(() => executor.apply(), /temporary failure/);
  await executor.apply();
  assert.equal(attempts, 2);
});

test('SQL deadlock executor requires one victim and one completed transaction', async () => {
  let requestIndex = 0;
  const connection = {
    request: () => ({
      batch: async () => {
        requestIndex += 1;
        if (requestIndex === 1) throw Object.assign(new Error('deadlock victim'), { number: 1205 });
        return {};
      },
    }),
  };
  const executor = createSqlExecutors('fixed-connection', { connect: async () => connection })['sql-deadlock'];
  await executor.apply();
  assert.equal(requestIndex, 2);
});

test('SQL deadlock executor rejects when no transaction completes', async () => {
  const connection = {
    request: () => ({ batch: async () => { throw new Error('connection lost'); } }),
  };
  const executor = createSqlExecutors('fixed-connection', { connect: async () => connection })['sql-deadlock'];
  await assert.rejects(() => executor.apply(), /not observed/);
});
