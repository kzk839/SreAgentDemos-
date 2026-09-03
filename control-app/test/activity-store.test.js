'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createActivityStore, validateDashboardQuery } = require('../src/activity-store');

async function* entities(items) {
  yield* items;
}

test('aggregates the activity writer contract and leaves empty rates null', async () => {
  const store = createActivityStore({
    now: () => new Date('2026-09-03T06:01:00.000Z'),
    tableClient: {
      listEntities: () => entities([
        { timestamp: '2026-09-03T06:00:40.000Z', source: 'AUTO', operationType: 'READ', success: true },
        { timestamp: '2026-09-03T06:00:45.000Z', source: 'AUTO', operationType: 'READ', success: false },
        { timestamp: '2026-09-03T06:00:50.000Z', source: 'USER', operationType: 'CREATE', success: true },
      ]),
    },
  });

  const result = await store.dashboard({ window: '5m', bucket: '10s', source: 'AUTO', type: 'READ' });
  assert.deepEqual(result.summary, { totalCount: 2, successCount: 1, failureCount: 1, successRate: 50 });
  assert.equal(result.series.at(-2).successRate, 50);
  assert.equal(result.series.at(-1).successRate, null);
});

test('rejects values outside the dashboard allowlists', () => {
  assert.throws(() => validateDashboardQuery({ window: '24h' }), /Invalid window/);
  assert.throws(() => validateDashboardQuery({ source: 'SYSTEM' }), /Invalid source/);
  assert.throws(() => validateDashboardQuery({ type: 'DROP' }), /Invalid type/);
});