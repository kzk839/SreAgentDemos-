'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');

function fixture(options = {}) {
  const calls = [];
  const app = createApp({
    authDisabled: options.authDisabled ?? true,
    mutationsEnabled: options.mutationsEnabled ?? true,
    activityStore: { dashboard: async () => ({ summary: { successCount: 0, failureCount: 0, successRate: null }, series: [] }), clear: async () => calls.push('clear') },
    auditStore: { write: async entry => calls.push(entry.action) },
    faultController: { list: async () => [], start: async id => ({ id }), stop: async id => ({ id }), stopAll: async () => { calls.push('stopAll'); return []; } },
  });
  return { app, calls };
}

function principal(roles) {
  return Buffer.from(JSON.stringify({ claims: roles.map(val => ({ typ: 'roles', val })) })).toString('base64');
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
    const response = await fetch(`${base}/api/reset`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
    assert.equal(response.status, 200);
  });
  assert.deepEqual(calls, ['stopAll', 'clear', 'reset']);
});

test('requires the Container Apps principal when auth is enabled', async () => {
  const { app } = fixture({ authDisabled: false });
  await withServer(app, async base => assert.equal((await fetch(`${base}/api/faults`)).status, 401));
});

test('enforces Reader and Operator roles and same-origin mutations', async () => {
  const { app } = fixture({ authDisabled: false });
  await withServer(app, async base => {
    const reader = { 'X-MS-CLIENT-PRINCIPAL': principal(['Reader']) };
    assert.equal((await fetch(`${base}/api/faults`, { headers: reader })).status, 200);
    assert.equal((await fetch(`${base}/api/faults/app-exception/start`, { method: 'POST', headers: { ...reader, Origin: base, 'Content-Type': 'application/json' }, body: '{}' })).status, 403);
    const operator = { 'X-MS-CLIENT-PRINCIPAL': principal(['Operator']), Origin: base, 'Content-Type': 'application/json' };
    assert.equal((await fetch(`${base}/api/faults/app-exception/start`, { method: 'POST', headers: operator, body: JSON.stringify({ command: 'whoami' }) })).status, 400);
    assert.equal((await fetch(`${base}/api/faults/app-exception/start`, { method: 'POST', headers: { ...operator, Origin: 'https://example.invalid' }, body: '{}' })).status, 403);
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