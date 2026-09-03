'use strict';

const { randomUUID } = require('node:crypto');
const { TableClient } = require('@azure/data-tables');
const { DefaultAzureCredential } = require('@azure/identity');

const VALID_SOURCES = new Set(['AUTO', 'USER']);

function minutePartition(timestamp) {
  return timestamp.toISOString().slice(0, 16).replace(/[-:T]/g, '');
}

function createActivityWriter(options = {}) {
  const {
    maxRecent = 50,
    now = () => new Date(),
    operationIdFactory = randomUUID,
    logger = console,
  } = options;

  let tableClient = options.tableClient;
  if (!tableClient && options.tableEndpoint) {
    tableClient = new TableClient(
      options.tableEndpoint,
      options.tableName || 'ActivityEvents',
      options.credential || new DefaultAzureCredential(),
    );
  }

  const recent = [];

  async function write(activity) {
    if (!VALID_SOURCES.has(activity.source)) {
      throw new TypeError('activity source must be AUTO or USER');
    }
    if (!activity.operationType) {
      throw new TypeError('activity operationType is required');
    }

    const timestamp = activity.timestamp ? new Date(activity.timestamp) : now();
    if (Number.isNaN(timestamp.getTime())) {
      throw new TypeError('activity timestamp must be a valid date');
    }

    const operationId = activity.operationId || operationIdFactory();
    const event = {
      operationId,
      source: activity.source,
      operationType: String(activity.operationType).toUpperCase(),
      success: Boolean(activity.success),
      durationMs: Number.isFinite(activity.durationMs) ? Math.max(0, activity.durationMs) : null,
      timestamp: timestamp.toISOString(),
      detail: activity.detail || '',
    };

    const existingIndex = recent.findIndex(item => item.operationId === operationId);
    if (existingIndex >= 0) recent.splice(existingIndex, 1);
    recent.unshift(event);
    if (recent.length > maxRecent) recent.length = maxRecent;

    if (tableClient) {
      try {
        await tableClient.upsertEntity({
          partitionKey: minutePartition(timestamp),
          rowKey: operationId,
          ...event,
        }, 'Replace');
      } catch (err) {
        logger.error('Activity persistence failed:', err.message);
      }
    }

    return event;
  }

  return {
    write,
    getRecent: () => recent.map(event => ({ ...event })),
  };
}

module.exports = { createActivityWriter, minutePartition };