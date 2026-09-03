'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createActivityWriter, minutePartition } = require('../src/activity-writer');

test('writes an idempotent event to memory and table storage', async () => {
  const entities = [];
  const writer = createActivityWriter({
    tableClient: { upsertEntity: async entity => entities.push(entity) },
    now: () => new Date('2026-09-03T06:07:08.000Z'),
  });

  await writer.write({ operationId: 'operation-1', source: 'USER', operationType: 'create', success: true, durationMs: 12 });
  await writer.write({ operationId: 'operation-1', source: 'USER', operationType: 'create', success: false, durationMs: 18 });

  assert.equal(writer.getRecent().length, 1);
  assert.equal(writer.getRecent()[0].success, false);
  assert.equal(entities[0].partitionKey, '202609030607');
  assert.equal(entities[0].rowKey, 'operation-1');
  assert.equal(entities[0].operationType, 'CREATE');
});

test('keeps the in-memory event when table storage fails', async () => {
  const errors = [];
  const writer = createActivityWriter({
    tableClient: { upsertEntity: async () => { throw new Error('storage unavailable'); } },
    logger: { error: (...args) => errors.push(args) },
  });

  await writer.write({ source: 'AUTO', operationType: 'READ', success: true, durationMs: 3 });

  assert.equal(writer.getRecent().length, 1);
  assert.equal(errors.length, 1);
});

test('validates source and creates UTC minute partitions', async () => {
  const writer = createActivityWriter();
  await assert.rejects(
    writer.write({ source: 'OTHER', operationType: 'READ', success: true }),
    /AUTO or USER/,
  );
  assert.equal(minutePartition(new Date('2026-09-03T23:59:59Z')), '202609032359');
});