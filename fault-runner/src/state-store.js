'use strict';

const { TableClient } = require('@azure/data-tables');

function createStateStore({ endpoint, tableName = 'FaultState', environmentId, credential, client: suppliedClient }) {
  const client = suppliedClient || new TableClient(endpoint, tableName, credential);

  async function get(faultId) {
    try {
      return await client.getEntity(environmentId, faultId);
    } catch (error) {
      if (error.statusCode === 404) return null;
      throw error;
    }
  }

  async function list() {
    const entities = [];
    const escaped = environmentId.replace(/'/g, "''");
    for await (const entity of client.listEntities({ queryOptions: { filter: `PartitionKey eq '${escaped}'` } })) {
      entities.push(entity);
    }
    return entities;
  }

  async function updateObserved(current, patch) {
    try {
      await client.updateEntity({
        partitionKey: environmentId,
        rowKey: current.rowKey,
        ...patch,
      }, 'Merge', { etag: current.etag });
      return true;
    } catch (error) {
      if (error.statusCode === 409 || error.statusCode === 412) return false;
      throw error;
    }
  }

  async function claim(current, { ownerId, executionId, now, leaseDurationMs }) {
    const leaseUntil = current.leaseUntil ? new Date(current.leaseUntil).getTime() : 0;
    if (leaseUntil > now.getTime() && current.executionOwner !== ownerId) return null;
    try {
      await client.updateEntity({
        partitionKey: environmentId,
        rowKey: current.rowKey,
        executionOwner: ownerId,
        executionId,
        leaseUntil: new Date(now.getTime() + leaseDurationMs).toISOString(),
      }, 'Merge', { etag: current.etag });
      const claimed = await get(current.rowKey);
      return claimed?.executionId === executionId && Number(claimed.generation) === Number(current.generation) ? claimed : null;
    } catch (error) {
      if (error.statusCode === 409 || error.statusCode === 412) return null;
      throw error;
    }
  }

  async function renewLease(current, { executionId, now, leaseDurationMs }) {
    if (current.executionId !== executionId) return null;
    try {
      await client.updateEntity({
        partitionKey: environmentId,
        rowKey: current.rowKey,
        leaseUntil: new Date(now.getTime() + leaseDurationMs).toISOString(),
      }, 'Merge', { etag: current.etag });
      const renewed = await get(current.rowKey);
      return renewed?.executionId === executionId && Number(renewed.generation) === Number(current.generation) ? renewed : null;
    } catch (error) {
      if (error.statusCode === 409 || error.statusCode === 412) return null;
      throw error;
    }
  }

  return { claim, get, list, renewLease, updateObserved };
}

module.exports = { createStateStore };
