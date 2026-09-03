'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createStateStore } = require('../src/state-store');

test('does not claim a fault when its generation changes concurrently', async () => {
  const client = {
    getEntity: async () => ({ partitionKey: 'env', rowKey: 'vm-cpu-high', generation: 2, etag: 'new' }),
    updateEntity: async () => {},
  };
  const store = createStateStore({ client, endpoint: 'https://unused', environmentId: 'env' });
  const claimed = await store.claim(
    { rowKey: 'vm-cpu-high', generation: 1, etag: 'read-etag' },
    { ownerId: 'runner-1', executionId: 'execution-1', now: new Date('2026-01-01T00:00:00Z'), leaseDurationMs: 120_000 },
  );
  assert.equal(claimed, null);
});

test('preserves the read ETag and treats a concurrent update as retryable', async () => {
  const calls = [];
  const client = {
    updateEntity: async (...args) => {
      calls.push(args);
      throw Object.assign(new Error('precondition failed'), { statusCode: 412 });
    },
  };
  const store = createStateStore({ client, endpoint: 'https://unused', environmentId: 'env' });
  const updated = await store.updateObserved({ rowKey: 'vm-cpu-high', generation: 1, etag: 'read-etag' }, { observedState: 'active' });
  assert.equal(updated, false);
  assert.equal(calls[0][2].etag, 'read-etag');
});

test('claims a fault with compare-and-swap before execution', async () => {
  const calls = [];
  const client = {
    updateEntity: async (...args) => calls.push(args),
    getEntity: async () => ({ rowKey: 'vm-cpu-high', generation: 1, etag: 'claimed', executionId: 'execution-1' }),
  };
  const store = createStateStore({ client, endpoint: 'https://unused', environmentId: 'env' });
  const claimed = await store.claim(
    { rowKey: 'vm-cpu-high', generation: 1, etag: 'read-etag' },
    { ownerId: 'runner-1', executionId: 'execution-1', now: new Date('2026-01-01T00:00:00Z'), leaseDurationMs: 120_000 },
  );
  assert.equal(calls[0][2].etag, 'read-etag');
  assert.equal(claimed.etag, 'claimed');
});

test('renews a lease only while the execution still owns it', async () => {
  const calls = [];
  const client = {
    updateEntity: async (...args) => calls.push(args),
    getEntity: async () => ({ rowKey: 'vm-cpu-high', generation: 1, etag: 'renewed', executionId: 'execution-1' }),
  };
  const store = createStateStore({ client, endpoint: 'https://unused', environmentId: 'env' });
  const renewed = await store.renewLease(
    { rowKey: 'vm-cpu-high', generation: 1, etag: 'claimed', executionId: 'execution-1' },
    { executionId: 'execution-1', now: new Date('2026-01-01T00:01:00Z'), leaseDurationMs: 120_000 },
  );
  assert.equal(calls[0][2].etag, 'claimed');
  assert.equal(renewed.etag, 'renewed');
});
