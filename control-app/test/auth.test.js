'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { parsePrincipal } = require('../src/auth');

test('parses Container Apps principal roles and identity claims', () => {
  const encoded = Buffer.from(JSON.stringify({ claims: [
    { typ: 'http://schemas.microsoft.com/identity/claims/objectidentifier', val: 'user-1' },
    { typ: 'http://schemas.microsoft.com/ws/2008/06/identity/claims/role', val: 'Reader' },
    { typ: 'roles', val: 'Operator' },
  ] })).toString('base64');
  assert.deepEqual(parsePrincipal(encoded), { userId: 'user-1', name: 'Unknown user', roles: ['Reader', 'Operator'] });
  assert.equal(parsePrincipal('not-json'), null);
});