'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createWorkload } = require('../src/workload');

test('runs READ and WRITE workers as AUTO activities', async () => {
  const scheduled = [];
  const activities = [];
  let clock = 10;
  const workload = createWorkload({
    read: async () => '3 items fetched',
    write: async () => 'Item #1 updated',
    activityWriter: { write: async activity => activities.push(activity) },
    random: () => 0,
    nowMs: () => clock++,
    setTimeoutFn: (callback, delay) => {
      scheduled.push({ callback, delay });
      return scheduled.length;
    },
    clearTimeoutFn: () => {},
  });

  workload.start();
  assert.deepEqual(scheduled.slice(0, 2).map(item => item.delay), [10000, 15000]);
  await scheduled[0].callback();
  await scheduled[1].callback();

  assert.deepEqual(activities.map(item => [item.source, item.operationType, item.success]), [
    ['AUTO', 'READ', true],
    ['AUTO', 'WRITE', true],
  ]);
});

test('records failures and stop clears scheduled workers', async () => {
  const scheduled = [];
  const cleared = [];
  const activities = [];
  const workload = createWorkload({
    read: async () => { throw new Error('read failed'); },
    write: async () => '',
    activityWriter: { write: async activity => activities.push(activity) },
    setTimeoutFn: callback => {
      const timer = { callback };
      scheduled.push(timer);
      return timer;
    },
    clearTimeoutFn: timer => cleared.push(timer),
    logger: { error: () => {} },
  });

  workload.start();
  await scheduled[0].callback();
  workload.stop();

  assert.equal(activities[0].source, 'AUTO');
  assert.equal(activities[0].success, false);
  assert.match(activities[0].detail, /read failed/);
  assert.equal(workload.isRunning(), false);
  assert.ok(cleared.length >= 2);
});