'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createReconciler } = require('../src/reconciler');

test('marks a stale transition as failed', async () => {
  const updates = [];
  const store = {
    list: async () => [{ rowKey: 'vm-cpu-high', desiredState: 'active', observedState: 'inactive', generation: 1, requestedAt: '2026-01-01T00:00:00Z' }],
    updateObserved: async (_entity, update) => updates.push(update),
  };
  const reconciler = createReconciler({ store, now: () => new Date('2026-01-01T00:03:00Z') });
  await reconciler.runOnce();
  assert.equal(updates[0].observedState, 'failed');
  assert.match(updates[0].lastError, /timed out/);
});

test('does not fail a fresh transition or an application fault', async () => {
  const updates = [];
  const store = {
    list: async () => [
      { rowKey: 'vm-cpu-high', desiredState: 'active', observedState: 'inactive', requestedAt: '2026-01-01T00:02:30Z' },
      { rowKey: 'app-latency', desiredState: 'active', observedState: 'inactive', requestedAt: '2026-01-01T00:00:00Z' },
    ],
    updateObserved: async (_entity, update) => updates.push(update),
  };
  await createReconciler({ store, now: () => new Date('2026-01-01T00:03:00Z') }).runOnce();
  assert.equal(updates.length, 0);
});
