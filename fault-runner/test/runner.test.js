'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createFaultRunner } = require('../src/runner');
const { createStateStore } = require('../src/state-store');

function fixture(desiredState) {
  const entity = { rowKey: 'vm-cpu-high', desiredState, etag: 'etag-1' };
  const updates = [];
  const calls = [];
  const store = {
    get: async () => entity,
    updateObserved: async (_current, update) => updates.push(update),
  };
  const executors = {
    'vm-cpu-high': {
      apply: async () => { calls.push('apply'); return { recoveryData: { task: 'SreFaultCpu' } }; },
      revert: async () => { calls.push('revert'); return {}; },
    },
  };
  const runner = createFaultRunner({ store, executors, now: () => new Date('2026-01-01T00:00:00Z'), logger: { error() {} } });
  return { runner, calls, updates };
}

test('applies a requested active fault and records recovery data', async () => {
  const { runner, calls, updates } = fixture('active');
  await runner.reconcileFault('vm-cpu-high');
  assert.deepEqual(calls, ['apply']);
  assert.equal(updates[0].observedState, 'active');
  assert.equal(JSON.parse(updates[0].recoveryData).task, 'SreFaultCpu');
});

test('reverts a requested inactive fault', async () => {
  const { runner, calls, updates } = fixture('inactive');
  await runner.reconcileFault('vm-cpu-high');
  assert.deepEqual(calls, ['revert']);
  assert.equal(updates[0].observedState, 'inactive');
});

test('records a bounded error without claiming success', async () => {
  const { runner, updates } = fixture('active');
  const store = {
    get: async () => ({ rowKey: 'vm-cpu-high', desiredState: 'active', etag: 'etag-1' }),
    updateObserved: async (_current, update) => updates.push(update),
  };
  const failedRunner = createFaultRunner({
    store,
    executors: { 'vm-cpu-high': { apply: async () => { throw new Error('apply failed'); } } },
    now: () => new Date('2026-01-01T00:00:00Z'),
    logger: { error() {} },
  });
  await failedRunner.reconcileFault('vm-cpu-high');
  assert.equal(updates[0].observedState, 'failed');
  assert.equal(updates[0].lastError, 'apply failed');
});

test('does not repeat a converged VM action', async () => {
  const calls = [];
  const updates = [];
  const runner = createFaultRunner({
    store: {
      get: async () => ({ rowKey: 'vm-cpu-high', desiredState: 'active', observedState: 'active', generation: 1 }),
      updateObserved: async (_current, update) => updates.push(update),
    },
    executors: { 'vm-cpu-high': { apply: async () => calls.push('apply') } },
    now: () => new Date('2026-01-01T00:00:00Z'),
  });
  await runner.reconcileFault('vm-cpu-high');
  assert.deepEqual(calls, []);
  assert.equal(updates[0].lastHeartbeatAt, '2026-01-01T00:00:00.000Z');
});

test('updates heartbeat for a converged inactive fault', async () => {
  const updates = [];
  const runner = createFaultRunner({
    store: {
      get: async () => ({ rowKey: 'vm-cpu-high', desiredState: 'inactive', observedState: 'inactive', generation: 2 }),
      updateObserved: async (_current, update) => updates.push(update),
    },
    executors: { 'vm-cpu-high': {} },
    now: () => new Date('2026-01-01T00:00:00Z'),
  });
  await runner.reconcileFault('vm-cpu-high');
  assert.equal(updates[0].lastHeartbeatAt, '2026-01-01T00:00:00.000Z');
});

test('reapplies an active fault when verification detects drift', async () => {
  const calls = [];
  const updates = [];
  const runner = createFaultRunner({
    store: {
      get: async () => ({ rowKey: 'vm-cpu-high', desiredState: 'active', observedState: 'active', generation: 3, lastVerifiedAt: '2025-12-31T23:58:00Z' }),
      updateObserved: async (_current, update) => updates.push(update),
    },
    executors: {
      'vm-cpu-high': {
        verify: async () => false,
        apply: async () => { calls.push('apply'); return {}; },
      },
    },
    now: () => new Date('2026-01-01T00:00:00Z'),
  });
  await runner.reconcileFault('vm-cpu-high');
  assert.deepEqual(calls, ['apply']);
  assert.equal(updates[0].observedState, 'active');
});

test('runs fault reconciliation independently', async () => {
  let releaseSlowFault;
  const slowFault = new Promise(resolve => { releaseSlowFault = resolve; });
  const updates = [];
  const runner = createFaultRunner({
    store: {
      get: async faultId => faultId === 'vm-cpu-high'
        ? { rowKey: faultId, desiredState: 'active' }
        : faultId === 'vm-memory-high' ? { rowKey: faultId, desiredState: 'active' } : null,
      updateObserved: async entity => updates.push(entity.rowKey),
    },
    executors: {
      'vm-cpu-high': { apply: async () => slowFault },
      'vm-memory-high': { apply: async () => ({}) },
    },
  });
  const run = runner.runOnce();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(updates, ['vm-memory-high']);
  releaseSlowFault({});
  await run;
});

test('repeats an active continuous fault in a one-shot run', async () => {
  const calls = [];
  const runner = createFaultRunner({
    store: {
      get: async faultId => faultId === 'sql-high-load'
        ? { rowKey: faultId, desiredState: 'active', observedState: 'active' }
        : null,
      updateObserved: async () => {},
    },
    executors: {
      'sql-high-load': { repeatWhileActive: true, apply: async () => { calls.push('apply'); return {}; } },
    },
  });
  await runner.runOnce();
  assert.deepEqual(calls, ['apply']);
});

test('does not execute an external action without acquiring the lease', async () => {
  const calls = [];
  const runner = createFaultRunner({
    store: {
      get: async () => ({ rowKey: 'vm-cpu-high', desiredState: 'active', generation: 1, etag: 'read-etag' }),
      claim: async () => null,
      updateObserved: async () => {},
    },
    executors: { 'vm-cpu-high': { apply: async () => calls.push('apply') } },
  });
  await runner.reconcileFault('vm-cpu-high');
  assert.deepEqual(calls, []);
});

test('records execution failure using the claimed entity', async () => {
  const updates = [];
  const runner = createFaultRunner({
    store: {
      get: async () => ({ rowKey: 'vm-cpu-high', desiredState: 'active', generation: 1, etag: 'read-etag' }),
      claim: async entity => ({ ...entity, etag: 'claimed-etag' }),
      updateObserved: async (entity, update) => updates.push({ entity, update }),
    },
    executors: { 'vm-cpu-high': { apply: async () => { throw new Error('apply failed'); } } },
    logger: { error() {} },
  });
  await runner.reconcileFault('vm-cpu-high');
  assert.equal(updates[0].entity.etag, 'claimed-etag');
  assert.equal(updates[0].update.leaseUntil, '');
});

test('renews the lease while an external action is running', async () => {
  let renewalCallback;
  let finishApply;
  const applyPending = new Promise(resolve => { finishApply = resolve; });
  const renewals = [];
  const runner = createFaultRunner({
    store: {
      get: async () => ({ rowKey: 'vm-cpu-high', desiredState: 'active', generation: 1, etag: 'read-etag' }),
      claim: async entity => ({ ...entity, etag: 'claimed-etag', executionId: 'execution-1' }),
      renewLease: async entity => {
        renewals.push(entity.etag);
        return { ...entity, etag: 'renewed-etag' };
      },
      updateObserved: async () => {},
    },
    executors: { 'vm-cpu-high': { apply: async () => applyPending } },
    scheduleInterval: callback => { renewalCallback = callback; return 1; },
    cancelInterval: () => {},
  });
  const reconciliation = runner.reconcileFault('vm-cpu-high');
  await new Promise(resolve => setImmediate(resolve));
  renewalCallback();
  await new Promise(resolve => setImmediate(resolve));
  finishApply({});
  await reconciliation;
  assert.deepEqual(renewals, ['claimed-etag']);
});

test('does not clear lease fields when verification fails before claim', async () => {
  const updates = [];
  const runner = createFaultRunner({
    store: {
      get: async () => ({ rowKey: 'vm-cpu-high', desiredState: 'active', observedState: 'active', generation: 1, etag: 'owned-etag', executionOwner: 'other-runner' }),
      updateObserved: async (_entity, update) => updates.push(update),
    },
    executors: { 'vm-cpu-high': { verify: async () => { throw new Error('verify failed'); } } },
    now: () => new Date('2026-01-01T00:02:00Z'),
    logger: { error() {} },
  });
  await runner.reconcileFault('vm-cpu-high');
  assert.equal(updates[0].observedState, 'failed');
  assert.equal(Object.hasOwn(updates[0], 'leaseUntil'), false);
});

test('rejects a delayed result after the desired-state generation changes', async () => {
  let entity = { partitionKey: 'env', rowKey: 'vm-cpu-high', desiredState: 'active', generation: 1, etag: 'etag-1' };
  let finishApply;
  const applyPending = new Promise(resolve => { finishApply = resolve; });
  const client = {
    getEntity: async () => ({ ...entity }),
    updateEntity: async (patch, _mode, options) => {
      if (options.etag !== entity.etag) throw Object.assign(new Error('precondition failed'), { statusCode: 412 });
      entity = { ...entity, ...patch, etag: `etag-${Number(entity.etag.slice(5)) + 1}` };
    },
  };
  const store = createStateStore({ client, endpoint: 'https://unused', environmentId: 'env' });
  const runner = createFaultRunner({
    store,
    executors: { 'vm-cpu-high': { apply: async () => applyPending } },
    scheduleInterval: () => 1,
    cancelInterval: () => {},
    logger: { error() {} },
  });
  const reconciliation = runner.reconcileFault('vm-cpu-high');
  await new Promise(resolve => setImmediate(resolve));
  entity = { ...entity, desiredState: 'inactive', generation: 2, etag: 'etag-3' };
  finishApply({});
  await reconciliation;
  assert.equal(entity.generation, 2);
  assert.equal(entity.desiredState, 'inactive');
  assert.notEqual(entity.observedState, 'active');
});
