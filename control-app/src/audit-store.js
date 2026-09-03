'use strict';

const { randomUUID } = require('node:crypto');

function createAuditStore(options = {}) {
  const tableClient = options.tableClient;
  const now = options.now || (() => new Date());
  const operationIdFactory = options.operationIdFactory || randomUUID;

  async function write(entry) {
    const timestamp = now();
    const operationId = entry.operationId || operationIdFactory();
    const entity = {
      partitionKey: timestamp.toISOString().slice(0, 10).replaceAll('-', ''),
      rowKey: operationId,
      operationId,
      action: entry.action,
      faultId: entry.faultId || '',
      requestedBy: entry.requestedBy,
      requestedAt: timestamp.toISOString(),
      result: entry.result,
      generation: entry.generation ?? null,
      parameters: JSON.stringify(entry.parameters || {}),
    };
    if (tableClient) await tableClient.createEntity(entity);
    return entity;
  }

  return { write };
}

module.exports = { createAuditStore };