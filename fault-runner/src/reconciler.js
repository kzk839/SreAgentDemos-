'use strict';

const { EXECUTED_FAULT_IDS } = require('./runner');

function createReconciler({ store, now = () => new Date(), staleAfterMs = 120_000 }) {
  async function runOnce() {
    const entities = await store.list();
    for (const entity of entities) {
      if (!EXECUTED_FAULT_IDS.includes(entity.rowKey)) continue;
      const desired = entity.desiredState === 'active' ? 'active' : 'inactive';
      if (entity.observedState === desired) continue;
      const lastUpdate = new Date(entity.lastHeartbeatAt || entity.requestedAt || 0).getTime();
      if (Number.isFinite(lastUpdate) && now().getTime() - lastUpdate <= staleAfterMs) continue;
      await store.updateObserved(entity, {
        observedState: 'failed',
        lastHeartbeatAt: now().toISOString(),
        lastError: `Reconciliation timed out while waiting for ${desired}`,
      });
    }
  }

  return { runOnce };
}

module.exports = { createReconciler };
