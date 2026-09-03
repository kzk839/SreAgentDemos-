'use strict';

const { TableClient } = require('@azure/data-tables');
const { DefaultAzureCredential } = require('@azure/identity');

const FAULT_IDS = ['app-exception', 'app-latency', 'app-n-plus-one'];

function escapeOData(value) {
  return String(value).replace(/'/g, "''");
}

function parseParameters(parameters) {
  if (!parameters) return {};
  if (typeof parameters === 'object') return parameters;
  try {
    const parsed = JSON.parse(parameters);
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch (_) {
    return {};
  }
}

function createFaultAdapter(options = {}) {
  const environmentId = options.environmentId || 'default';
  const pollIntervalMs = options.pollIntervalMs || 5000;
  const maxLatencyMs = options.maxLatencyMs || 10000;
  const now = options.now || (() => new Date());
  const logger = options.logger || console;
  const setIntervalFn = options.setIntervalFn || setInterval;
  const clearIntervalFn = options.clearIntervalFn || clearInterval;

  let tableClient = options.tableClient;
  if (!tableClient && options.tableEndpoint) {
    tableClient = new TableClient(
      options.tableEndpoint,
      options.tableName || 'FaultState',
      options.credential || new DefaultAzureCredential(),
    );
  }

  const loadFaultStates = options.loadFaultStates || (async () => {
    if (!tableClient) return [];
    const entities = [];
    const filter = `PartitionKey eq '${escapeOData(environmentId)}'`;
    for await (const entity of tableClient.listEntities({ queryOptions: { filter } })) {
      entities.push(entity);
    }
    return entities;
  });

  const writeObserved = options.writeObserved || (async (entity, observedState, heartbeat) => {
    if (!tableClient) return;
    await tableClient.updateEntity({
      partitionKey: entity.partitionKey,
      rowKey: entity.rowKey,
      generation: entity.generation,
      observedState,
      lastHeartbeatAt: heartbeat,
      lastError: '',
    }, 'Merge', entity.etag ? { etag: entity.etag } : undefined);
  });

  const states = new Map(FAULT_IDS.map(id => [id, {
    active: false,
    generation: -1,
    parameters: {},
  }]));
  let interval = null;
  let polling = false;

  async function poll() {
    if (polling) return;
    polling = true;
    try {
      const entities = await loadFaultStates();
      for (const entity of entities) {
        const faultId = entity.rowKey;
        if (!states.has(faultId)) continue;

        const desiredState = String(entity.desiredState || '').toLowerCase();
        if (desiredState !== 'active' && desiredState !== 'inactive') continue;

        const generation = Number(entity.generation) || 0;
        const parameters = parseParameters(entity.parameters);
        states.set(faultId, {
          active: desiredState === 'active',
          generation,
          parameters,
        });

        try {
          await writeObserved(entity, desiredState, now().toISOString());
        } catch (err) {
          logger.error(`Fault heartbeat failed for ${faultId}:`, err.message);
        }
      }
    } catch (err) {
      logger.error('Fault state polling failed:', err.message);
    } finally {
      polling = false;
    }
  }

  function start() {
    if (interval) return;
    void poll();
    interval = setIntervalFn(() => void poll(), pollIntervalMs);
  }

  function stop() {
    if (!interval) return;
    clearIntervalFn(interval);
    interval = null;
  }

  function isActive(faultId) {
    return Boolean(states.get(faultId)?.active);
  }

  function getLatencyMs() {
    if (!isActive('app-latency')) return 0;
    const delayMs = Number(states.get('app-latency').parameters.delayMs);
    if (!Number.isFinite(delayMs)) return 0;
    return Math.min(maxLatencyMs, Math.max(0, Math.floor(delayMs)));
  }

  return {
    start,
    stop,
    poll,
    isActive,
    getLatencyMs,
    getState: () => Object.fromEntries(
      [...states].map(([id, state]) => [id, { ...state, parameters: { ...state.parameters } }]),
    ),
  };
}

module.exports = { createFaultAdapter, FAULT_IDS, parseParameters };