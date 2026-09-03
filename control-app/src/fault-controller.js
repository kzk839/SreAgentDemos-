'use strict';

const { randomUUID } = require('node:crypto');

const FAULT_CATALOG = Object.freeze([
  { id: 'app-exception', target: 'Application', description: 'Return errors from item reads', impact: '5xx responses and failed READ operations' },
  { id: 'app-latency', target: 'Application', description: 'Delay application responses', impact: 'Increased response time', parameters: { delayMs: { default: 3000, min: 0, max: 10000 } } },
  { id: 'app-n-plus-one', target: 'Application', description: 'Enable repeated item queries', impact: 'More SQL dependencies and latency' },
  { id: 'vm-cpu-high', target: 'VM', description: 'Generate sustained CPU pressure', impact: 'High CPU alert and slow processing' },
  { id: 'vm-memory-high', target: 'VM', description: 'Generate bounded memory pressure', impact: 'High committed memory alert' },
  { id: 'vm-disk-pressure', target: 'VM', description: 'Fill the dedicated fault data disk', impact: 'Low free space alert' },
  { id: 'sql-high-load', target: 'Database', description: 'Generate SQL workload pressure', impact: 'High database utilization and latency' },
  { id: 'sql-deadlock', target: 'Database', description: 'Create controlled SQL deadlocks', impact: 'Deadlock errors and failed operations' },
  { id: 'network-deny', target: 'Network', description: 'Apply the catalogued deny rule', impact: 'Target connectivity failures' },
]);
const CATALOG_BY_ID = new Map(FAULT_CATALOG.map(fault => [fault.id, fault]));

function normalizeParameters(fault, value) {
  const parameters = value === undefined ? {} : value;
  if (!parameters || typeof parameters !== 'object' || Array.isArray(parameters)) throw new TypeError('parameters must be an object');
  const keys = Object.keys(parameters);
  const allowed = Object.keys(fault.parameters || {});
  if (keys.some(key => !allowed.includes(key))) throw new TypeError('Unsupported fault parameter');
  if (!fault.parameters) return {};
  const rule = fault.parameters.delayMs;
  const supplied = parameters.delayMs === undefined ? rule.default : Number(parameters.delayMs);
  if (!Number.isFinite(supplied) || supplied < rule.min) throw new TypeError('delayMs must be a non-negative number');
  return { delayMs: Math.min(rule.max, Math.floor(supplied)) };
}

function parseStoredParameters(value) {
  if (!value) return {};
  if (typeof value === 'object') return value;
  try { return JSON.parse(value); } catch (_) { return {}; }
}

function statusLabel(entity, now, heartbeatMaxAgeMs) {
  const observed = String(entity.observedState || 'inactive').toLowerCase();
  if (observed === 'failed') return 'failed';
  const heartbeat = entity.lastHeartbeatAt ? new Date(entity.lastHeartbeatAt).getTime() : NaN;
  const requested = entity.requestedAt ? new Date(entity.requestedAt).getTime() : NaN;
  const lastCheck = Number.isFinite(heartbeat) ? heartbeat : requested;
  if (entity.generation > 0 && Number.isFinite(lastCheck) && now.getTime() - lastCheck > heartbeatMaxAgeMs) return 'check-unavailable';
  if (entity.desiredState === 'active' && observed !== 'active') return 'starting';
  if (entity.desiredState === 'inactive' && observed !== 'inactive') return 'stopping';
  return observed === 'active' ? 'active' : 'inactive';
}

function createFaultController(options = {}) {
  const tableClient = options.tableClient;
  const auditStore = options.auditStore;
  const environmentId = options.environmentId || 'default';
  const now = options.now || (() => new Date());
  const operationIdFactory = options.operationIdFactory || randomUUID;
  const heartbeatMaxAgeMs = options.heartbeatMaxAgeMs || 30_000;
  const maxAttempts = options.maxAttempts || 4;

  function defaultEntity(id) {
    return { partitionKey: environmentId, rowKey: id, generation: 0, desiredState: 'inactive', observedState: 'inactive', parameters: '{}' };
  }

  async function read(id) {
    if (!tableClient) return defaultEntity(id);
    try { return await tableClient.getEntity(environmentId, id); }
    catch (error) {
      if (error.statusCode === 404) return null;
      throw error;
    }
  }

  function present(fault, entity) {
    const state = entity || defaultEntity(fault.id);
    return {
      ...fault,
      state: {
        status: statusLabel(state, now(), heartbeatMaxAgeMs),
        desiredState: state.desiredState || 'inactive',
        observedState: state.observedState || 'inactive',
        generation: Number(state.generation) || 0,
        requestedAt: state.requestedAt || null,
        appliedAt: state.appliedAt || null,
        lastHeartbeatAt: state.lastHeartbeatAt || null,
        lastError: state.lastError || '',
        parameters: parseStoredParameters(state.parameters),
      },
    };
  }

  async function list() {
    const entities = new Map();
    if (tableClient) {
      const escaped = environmentId.replace(/'/g, "''");
      for await (const entity of tableClient.listEntities({ queryOptions: { filter: `PartitionKey eq '${escaped}'` } })) {
        entities.set(entity.rowKey, entity);
      }
    }
    return FAULT_CATALOG.map(fault => present(fault, entities.get(fault.id)));
  }

  async function transition(id, desiredState, requestedBy, suppliedParameters) {
    const fault = CATALOG_BY_ID.get(id);
    if (!fault) throw Object.assign(new Error('Unknown fault'), { statusCode: 404 });
    const parameters = desiredState === 'active' ? normalizeParameters(fault, suppliedParameters) : {};

    for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
      const current = await read(id);
      if (current?.desiredState === desiredState) {
        await auditStore?.write({ action: desiredState === 'active' ? 'start' : 'stop', faultId: id, requestedBy, result: 'unchanged', generation: current.generation, parameters: parseStoredParameters(current.parameters) });
        return present(fault, current);
      }
      const operationId = operationIdFactory();
      const entity = {
        partitionKey: environmentId,
        rowKey: id,
        generation: (Number(current?.generation) || 0) + 1,
        desiredState,
        operationId,
        operationType: desiredState === 'active' ? 'apply' : 'revert',
        requestedBy,
        requestedAt: now().toISOString(),
        parameters: JSON.stringify(parameters),
        lastError: '',
      };
      try {
        if (!tableClient) {
          entity.observedState = 'inactive';
        } else if (current) {
          await tableClient.updateEntity(entity, 'Merge', { etag: current.etag });
        } else {
          entity.observedState = 'inactive';
          await tableClient.createEntity(entity);
        }
        await auditStore?.write({ action: entity.operationType, faultId: id, requestedBy, result: 'requested', operationId, generation: entity.generation, parameters });
        return present(fault, { ...current, ...entity });
      } catch (error) {
        if (error.statusCode !== 409 && error.statusCode !== 412) throw error;
      }
    }
    throw Object.assign(new Error('Fault state changed concurrently; retry the request'), { statusCode: 409 });
  }

  async function stopAll(requestedBy) {
    const results = [];
    for (const fault of FAULT_CATALOG) results.push(await transition(fault.id, 'inactive', requestedBy));
    return results;
  }

  return {
    list,
    start: (id, requestedBy, parameters) => transition(id, 'active', requestedBy, parameters),
    stop: (id, requestedBy) => transition(id, 'inactive', requestedBy),
    stopAll,
  };
}

module.exports = { FAULT_CATALOG, createFaultController, normalizeParameters, statusLabel };