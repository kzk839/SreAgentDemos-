'use strict';

const { randomUUID } = require('node:crypto');

const EXECUTED_FAULT_IDS = Object.freeze([
  'vm-cpu-high',
  'vm-memory-high',
  'vm-disk-pressure',
  'sql-high-load',
  'sql-deadlock',
  'network-deny',
]);

function createFaultRunner(options) {
  const { store, executors, now = () => new Date(), logger = console } = options;
  const repeatContinuous = options.repeatContinuous !== false;
  const ownerId = options.ownerId || randomUUID();
  const executionIdFactory = options.executionIdFactory || randomUUID;
  const leaseDurationMs = options.leaseDurationMs || 120_000;
  const scheduleInterval = options.scheduleInterval || setInterval;
  const cancelInterval = options.cancelInterval || clearInterval;

  async function reconcileFault(faultId) {
    const entity = await store.get(faultId);
    if (!entity) return;
    let updateTarget = entity;
    let hasClaim = false;

    const desiredState = entity.desiredState === 'active' ? 'active' : 'inactive';
    const executor = executors[faultId];
    if (!executor) throw new Error(`No executor registered for ${faultId}`);

    try {
      const isConverged = entity.observedState === desiredState;
      if (isConverged && !(repeatContinuous && desiredState === 'active' && executor.repeatWhileActive)) {
        const verifiedAt = entity.lastVerifiedAt ? new Date(entity.lastVerifiedAt).getTime() : 0;
        const verificationDue = desiredState === 'active' && executor.verify && now().getTime() - verifiedAt >= 60_000;
        if (!verificationDue || await executor.verify()) {
          await store.updateObserved(entity, {
            lastHeartbeatAt: now().toISOString(),
            ...(verificationDue ? { lastVerifiedAt: now().toISOString() } : {}),
          });
          return;
        }
      }

      const claimed = store.claim ? await store.claim(entity, {
        ownerId,
        executionId: executionIdFactory(),
        now: now(),
        leaseDurationMs,
      }) : entity;
      if (!claimed) return;
      updateTarget = claimed;
      hasClaim = true;
      let leaseLost = false;
      let renewal = Promise.resolve();
      const renewalTimer = store.renewLease && scheduleInterval(() => {
        renewal = renewal.then(async () => {
          const renewed = await store.renewLease(updateTarget, {
            executionId: claimed.executionId,
            now: now(),
            leaseDurationMs,
          });
          if (renewed) updateTarget = renewed;
          else leaseLost = true;
        }).catch(error => {
          leaseLost = true;
          logger.error(`Failed to renew lease for ${faultId}: ${error.message}`);
        });
      }, Math.max(1_000, Math.floor(leaseDurationMs / 3)));
      let result;
      try {
        result = desiredState === 'active'
          ? await executor.apply(claimed)
          : await executor.revert(claimed);
      } finally {
        if (renewalTimer) cancelInterval(renewalTimer);
        await renewal;
      }
      if (leaseLost) return;
      await store.updateObserved(updateTarget, {
        observedState: desiredState,
        appliedAt: desiredState === 'active' ? (entity.appliedAt || now().toISOString()) : '',
        lastHeartbeatAt: now().toISOString(),
        lastVerifiedAt: desiredState === 'active' ? now().toISOString() : '',
        recoveryData: JSON.stringify(result?.recoveryData || {}),
        lastError: '',
        executionOwner: '',
        executionId: '',
        leaseUntil: '',
      });
    } catch (error) {
      logger.error(`Failed to reconcile ${faultId}: ${error.message}`);
      await store.updateObserved(updateTarget, {
        observedState: 'failed',
        lastHeartbeatAt: now().toISOString(),
        lastError: String(error.message || error).slice(0, 1024),
        ...(hasClaim ? { executionOwner: '', executionId: '', leaseUntil: '' } : {}),
      });
    }
  }

  async function runOnce() {
    await Promise.allSettled(EXECUTED_FAULT_IDS.map(faultId => reconcileFault(faultId)));
  }

  async function runContinuously(intervalMs) {
    await Promise.all(EXECUTED_FAULT_IDS.map(async faultId => {
      while (true) {
        try {
          await reconcileFault(faultId);
        } catch (error) {
          logger.error(`Fault loop failed for ${faultId}: ${error.message}`);
        }
        await new Promise(resolve => setTimeout(resolve, intervalMs));
      }
    }));
  }

  return { runContinuously, runOnce, reconcileFault };
}

module.exports = { EXECUTED_FAULT_IDS, createFaultRunner };
