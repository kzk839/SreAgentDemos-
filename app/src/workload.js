'use strict';

function createWorkload(options) {
  const {
    read,
    write,
    activityWriter,
    random = Math.random,
    nowMs = Date.now,
    setTimeoutFn = setTimeout,
    clearTimeoutFn = clearTimeout,
    logger = console,
    readDelayRangeMs = [10000, 30000],
    writeDelayRangeMs = [15000, 45000],
  } = options;

  let running = false;
  const timers = new Set();

  function randomDelay([minimum, maximum]) {
    return Math.floor(random() * (maximum - minimum + 1)) + minimum;
  }

  async function run(operationType, operation) {
    const startedAt = nowMs();
    try {
      const result = await operation();
      await activityWriter.write({
        source: 'AUTO',
        operationType,
        success: true,
        durationMs: nowMs() - startedAt,
        detail: typeof result === 'string' ? result : '',
      });
    } catch (err) {
      logger.error(`AUTO ${operationType} failed:`, err.message);
      await activityWriter.write({
        source: 'AUTO',
        operationType,
        success: false,
        durationMs: nowMs() - startedAt,
        detail: err.message,
      });
    }
  }

  function schedule(operationType, operation, delayRange) {
    if (!running) return;
    const timer = setTimeoutFn(async () => {
      timers.delete(timer);
      await run(operationType, operation);
      schedule(operationType, operation, delayRange);
    }, randomDelay(delayRange));
    timers.add(timer);
  }

  function start() {
    if (running) return;
    running = true;
    schedule('READ', read, readDelayRangeMs);
    schedule('WRITE', write, writeDelayRangeMs);
  }

  function stop() {
    running = false;
    for (const timer of timers) clearTimeoutFn(timer);
    timers.clear();
  }

  return {
    start,
    stop,
    isRunning: () => running,
  };
}

module.exports = { createWorkload };