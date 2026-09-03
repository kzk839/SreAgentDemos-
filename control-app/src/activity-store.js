'use strict';

const WINDOWS = Object.freeze({ '5m': 5 * 60_000, '15m': 15 * 60_000, '1h': 60 * 60_000 });
const BUCKETS = Object.freeze({ '10s': 10_000, '30s': 30_000, '1m': 60_000 });
const SOURCES = new Set(['all', 'AUTO', 'USER']);
const TYPES = new Set(['all', 'READ', 'CREATE', 'UPDATE', 'DELETE']);

function minutePartition(date) {
  return date.toISOString().slice(0, 16).replace(/[-:T]/g, '');
}

function validateDashboardQuery(query = {}) {
  const values = {
    window: query.window || '15m',
    bucket: query.bucket || '30s',
    source: query.source || 'all',
    type: query.type || 'all',
  };
  if (!Object.hasOwn(WINDOWS, values.window)) throw new TypeError('Invalid window');
  if (!Object.hasOwn(BUCKETS, values.bucket)) throw new TypeError('Invalid bucket');
  if (!SOURCES.has(values.source)) throw new TypeError('Invalid source');
  if (!TYPES.has(values.type)) throw new TypeError('Invalid type');
  return values;
}

function createActivityStore(options = {}) {
  const tableClient = options.tableClient;
  const now = options.now || (() => new Date());

  async function dashboard(query) {
    const filters = validateDashboardQuery(query);
    const generatedAt = now();
    const windowStart = new Date(generatedAt.getTime() - WINDOWS[filters.window]);
    const bucketMs = BUCKETS[filters.bucket];
    const firstBucket = Math.floor(windowStart.getTime() / bucketMs) * bucketMs;
    const buckets = new Map();

    for (let start = firstBucket; start < generatedAt.getTime(); start += bucketMs) {
      buckets.set(start, { start: new Date(start).toISOString(), successCount: 0, failureCount: 0, successRate: null });
    }

    if (tableClient) {
      const partitionFilter = `PartitionKey ge '${minutePartition(windowStart)}' and PartitionKey le '${minutePartition(generatedAt)}'`;
      for await (const event of tableClient.listEntities({ queryOptions: { filter: partitionFilter } })) {
        const timestamp = new Date(event.timestamp);
        if (Number.isNaN(timestamp.getTime()) || timestamp < windowStart || timestamp > generatedAt) continue;
        if (filters.source !== 'all' && event.source !== filters.source) continue;
        if (filters.type !== 'all' && event.operationType !== filters.type) continue;
        const bucketStart = Math.floor(timestamp.getTime() / bucketMs) * bucketMs;
        const bucket = buckets.get(bucketStart);
        if (!bucket) continue;
        if (event.success === true) bucket.successCount += 1;
        else bucket.failureCount += 1;
      }
    }

    let successCount = 0;
    let failureCount = 0;
    for (const bucket of buckets.values()) {
      const count = bucket.successCount + bucket.failureCount;
      bucket.successRate = count === 0 ? null : Number(((bucket.successCount / count) * 100).toFixed(1));
      successCount += bucket.successCount;
      failureCount += bucket.failureCount;
    }
    const totalCount = successCount + failureCount;
    return {
      generatedAt: generatedAt.toISOString(),
      summary: {
        totalCount,
        successCount,
        failureCount,
        successRate: totalCount === 0 ? null : Number(((successCount / totalCount) * 100).toFixed(1)),
      },
      series: [...buckets.values()],
    };
  }

  async function clear() {
    if (!tableClient) return;
    for await (const entity of tableClient.listEntities()) {
      await tableClient.deleteEntity(entity.partitionKey, entity.rowKey, entity.etag ? { etag: entity.etag } : undefined);
    }
  }

  return { dashboard, clear };
}

module.exports = { BUCKETS, SOURCES, TYPES, WINDOWS, createActivityStore, minutePartition, validateDashboardQuery };