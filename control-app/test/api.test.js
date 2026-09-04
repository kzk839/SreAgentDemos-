'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');

function fixture(options = {}) {
  const calls = [];
  const app = createApp({
    mutationsEnabled: options.mutationsEnabled ?? true,
    activityStore: { dashboard: async () => ({ summary: { successCount: 0, failureCount: 0, successRate: null }, series: [] }), clear: async () => calls.push({ action: 'clear' }) },
    auditStore: { write: async entry => calls.push(entry) },
    faultController: {
      list: async () => [],
      start: async (id, requestedBy) => ({ id, requestedBy }),
      stop: async (id, requestedBy) => ({ id, requestedBy }),
      stopAll: async requestedBy => { calls.push({ action: 'stopAll', requestedBy }); return []; },
    },
  });
  return { app, calls };
}

async function withServer(app, action) {
  const server = app.listen(0);
  await new Promise(resolve => server.once('listening', resolve));
  try { await action(`http://127.0.0.1:${server.address().port}`); } finally { await new Promise(resolve => server.close(resolve)); }
}

test('serves health and reset preserves audit while clearing activity', async () => {
  const { app, calls } = fixture();
  await withServer(app, async base => {
    assert.equal((await fetch(`${base}/health`)).status, 200);
    const response = await fetch(`${base}/api/reset`, { method: 'POST', headers: { Origin: base, 'Content-Type': 'application/json' }, body: '{}' });
    assert.equal(response.status, 200);
  });
  assert.deepEqual(calls, [
    { action: 'stopAll', requestedBy: 'demo-operator' },
    { action: 'clear' },
    { action: 'reset', requestedBy: 'demo-operator', result: 'requested' },
  ]);
});

test('allows reads and enforces same-origin mutations', async () => {
  const { app } = fixture();
  await withServer(app, async base => {
    assert.equal((await fetch(`${base}/api/faults`)).status, 200);
    const sameOrigin = { Origin: base, 'Content-Type': 'application/json' };
    const started = await fetch(`${base}/api/faults/app-exception/start`, { method: 'POST', headers: sameOrigin, body: '{}' });
    assert.equal(started.status, 200);
    assert.equal((await started.json()).requestedBy, 'demo-operator');
    assert.equal((await fetch(`${base}/api/faults/app-exception/start`, { method: 'POST', headers: sameOrigin, body: JSON.stringify({ command: 'whoami' }) })).status, 400);
    assert.equal((await fetch(`${base}/api/faults/app-exception/start`, { method: 'POST', headers: { ...sameOrigin, Origin: 'https://example.invalid' }, body: '{}' })).status, 403);
  });
});

test('serves the local Chart.js browser bundle', async () => {
  const { app } = fixture();
  await withServer(app, async base => {
    const response = await fetch(`${base}/vendor/chart.umd.js`);
    assert.equal(response.status, 200);
    assert.match(await response.text(), /Chart/);
  });
});