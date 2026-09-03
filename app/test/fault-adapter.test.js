'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createFaultAdapter } = require('../src/fault-adapter');

test('applies only explicit active and inactive desired states', async () => {
  const heartbeats = [];
  let entities = [
    { rowKey: 'app-exception', desiredState: 'active', generation: 2 },
    { rowKey: 'app-latency', desiredState: 'active', generation: 3, parameters: JSON.stringify({ delayMs: 50000, duration: 1 }) },
    { rowKey: 'app-n-plus-one', desiredState: 'starting', generation: 4 },
  ];
  const adapter = createFaultAdapter({
    loadFaultStates: async () => entities,
    writeObserved: async (...args) => heartbeats.push(args),
    maxLatencyMs: 8000,
    now: () => new Date('2026-09-03T07:00:00Z'),
  });

  await adapter.poll();
  assert.equal(adapter.isActive('app-exception'), true);
  assert.equal(adapter.getLatencyMs(), 8000);
  assert.equal(adapter.isActive('app-n-plus-one'), false);
  assert.equal(heartbeats.length, 2);

  entities = [{ rowKey: 'app-exception', desiredState: 'inactive', generation: 3 }];
  await adapter.poll();
  assert.equal(adapter.isActive('app-exception'), false);
});

test('keeps the last observed fault state when storage polling fails', async () => {
  let fail = false;
  const errors = [];
  const adapter = createFaultAdapter({
    loadFaultStates: async () => {
      if (fail) throw new Error('unavailable');
      return [{ rowKey: 'app-n-plus-one', desiredState: 'active', generation: 1 }];
    },
    writeObserved: async () => {},
    logger: { error: (...args) => errors.push(args) },
  });

  await adapter.poll();
  fail = true;
  await adapter.poll();

  assert.equal(adapter.isActive('app-n-plus-one'), true);
  assert.equal(errors.length, 1);
});

test('starts one five-second poller and can stop it', () => {
  const intervals = [];
  const cleared = [];
  const adapter = createFaultAdapter({
    loadFaultStates: async () => [],
    setIntervalFn: (callback, delay) => {
      intervals.push({ callback, delay });
      return 42;
    },
    clearIntervalFn: id => cleared.push(id),
  });

  adapter.start();
  adapter.start();
  assert.equal(intervals.length, 1);
  assert.equal(intervals[0].delay, 5000);
  adapter.stop();
  assert.deepEqual(cleared, [42]);
});