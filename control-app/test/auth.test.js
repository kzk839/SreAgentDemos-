'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createAuthorization, DEMO_OPERATOR } = require('../src/auth');

test('assigns the fixed demo operator', () => {
  const authorization = createAuthorization();
  const request = {};
  authorization.authenticate(request, {}, () => {});
  assert.equal(request.principal, DEMO_OPERATOR);
});