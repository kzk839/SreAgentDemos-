'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createFaultController, normalizeParameters, statusLabel, FAULT_CATALOG } = require('../src/fault-controller');

async function* values(map) { yield* map.values(); }

function memoryTable() {
  const rows = new Map();
  let etag = 0;
  return {
    rows,
    getEntity: async (partitionKey, rowKey) => {
      const value = rows.get(`${partitionKey}/${rowKey}`);
      if (!value) throw Object.assign(new Error('missing'), { statusCode: 404 });
      return { ...value };
    },
    createEntity: async entity => { rows.set(`${entity.partitionKey}/${entity.rowKey}`, { ...entity, etag: String(++etag) }); },
    updateEntity: async (entity, _mode, options) => {
      const key = `${entity.partitionKey}/${entity.rowKey}`;
      const current = rows.get(key);
      if (current.etag !== options.etag) throw Object.assign(new Error('conflict'), { statusCode: 412 });
      rows.set(key, { ...current, ...entity, etag: String(++etag) });
    },
    listEntities: () => values(rows),
  };
}

test('uses ETags and keeps repeated desired state idempotent', async () => {
  const tableClient = memoryTable();
  const audits = [];
  const controller = createFaultController({ tableClient, auditStore: { write: async entry => audits.push(entry) }, environmentId: 'demo', operationIdFactory: () => 'op-1', now: () => new Date('2026-09-03T06:00:00Z') });
  const first = await controller.start('app-latency', 'operator-1', { delayMs: 50000 });
  const second = await controller.start('app-latency', 'operator-1', { delayMs: 20 });
  assert.equal(first.state.generation, 1);
  assert.equal(first.state.parameters.delayMs, 10000);
  assert.equal(second.state.generation, 1);
  assert.equal(audits[1].result, 'unchanged');
});

test('catalog is fixed and non-latency faults reject parameters', () => {
  assert.equal(FAULT_CATALOG.length, 9);
  assert.throws(() => normalizeParameters(FAULT_CATALOG[0], { command: 'whoami' }), /Unsupported/);
  assert.throws(() => normalizeParameters(FAULT_CATALOG[1], { duration: 10 }), /Unsupported/);
});

test('shows transition status before marking a stale heartbeat unavailable', () => {
  const state = { generation: 1, desiredState: 'active', observedState: 'inactive', requestedAt: '2026-09-03T06:00:00Z' };
  assert.equal(statusLabel(state, new Date('2026-09-03T06:00:10Z'), 30000), 'starting');
  assert.equal(statusLabel(state, new Date('2026-09-03T06:01:00Z'), 30000), 'check-unavailable');
});