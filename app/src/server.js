'use strict';

if (process.env.APPLICATIONINSIGHTS_CONNECTION_STRING) {
  const appInsights = require('applicationinsights');
  appInsights.setup(process.env.APPLICATIONINSIGHTS_CONNECTION_STRING)
    .setAutoCollectRequests(true).setAutoCollectPerformance(true)
    .setAutoCollectExceptions(true).setAutoCollectDependencies(true).start();
  appInsights.defaultClient.addTelemetryProcessor((envelope) => {
    const name = envelope.data?.baseData?.name || '';
    return !name.includes('/health') && !name.includes('/ready');
  });
}

const path = require('node:path');
const { randomUUID } = require('node:crypto');
const express = require('express');
const sql = require('mssql');
const { createActivityWriter } = require('./activity-writer');
const { createFaultAdapter } = require('./fault-adapter');
const { createWorkload } = require('./workload');

const PORT = Number(process.env.PORT) || 8080;
const tableEndpoint = process.env.AZURE_STORAGE_TABLE_ENDPOINT || process.env.TABLE_STORAGE_ENDPOINT;
const activityWriter = createActivityWriter({
  tableEndpoint,
  tableName: process.env.ACTIVITY_TABLE_NAME || 'ActivityEvents',
});
const faultAdapter = createFaultAdapter({
  tableEndpoint,
  tableName: process.env.FAULT_STATE_TABLE_NAME || 'FaultState',
  environmentId: process.env.FAULT_ENVIRONMENT_ID || 'default',
  pollIntervalMs: 5000,
  maxLatencyMs: Number(process.env.MAX_APP_FAULT_DELAY_MS) || 10000,
});

const sqlConfig = {
  connectionString: process.env.SQL_CONNECTION_STRING,
  pool: { max: 10, min: 0, idleTimeoutMillis: 30000 },
};
let pool = null;
let poolUseCount = 0;
const POOL_RESET_INTERVAL = 10;

async function getPool() {
  if (!sqlConfig.connectionString) throw new Error('SQL_CONNECTION_STRING is not configured');
  if (!pool) {
    pool = await sql.connect(sqlConfig.connectionString);
    poolUseCount = 0;
  }
  poolUseCount += 1;
  if (poolUseCount < POOL_RESET_INTERVAL) return pool;

  const oldPool = pool;
  pool = null;
  poolUseCount = 0;
  oldPool.close().catch(err => console.error('Pool close error:', err.message));
  return sql.connect(sqlConfig.connectionString);
}

async function closePool() {
  if (!pool) return;
  const oldPool = pool;
  pool = null;
  await oldPool.close();
}

async function initDb() {
  try {
    const connection = await getPool();
    await connection.request().query(`
      IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Items')
      CREATE TABLE Items (
        Id INT IDENTITY(1,1) PRIMARY KEY,
        Name NVARCHAR(200) NOT NULL,
        Status NVARCHAR(50) NOT NULL DEFAULT 'active',
        CreatedAt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
      )
    `);
    const faultRunnerPassword = process.env.SQL_FAULT_RUNNER_PASSWORD;
    if (faultRunnerPassword) {
      if (!/^[A-Za-z0-9+/=]{24,128}$/.test(faultRunnerPassword)) throw new Error('SQL_FAULT_RUNNER_PASSWORD has an invalid format');
      await connection.request().query(`
        IF OBJECT_ID('dbo.SreFaultLocks') IS NULL
        CREATE TABLE dbo.SreFaultLocks (Id INT NOT NULL PRIMARY KEY, Value INT NOT NULL);
        IF NOT EXISTS (SELECT 1 FROM dbo.SreFaultLocks)
        INSERT INTO dbo.SreFaultLocks (Id, Value) VALUES (1, 0), (2, 0);
        IF DATABASE_PRINCIPAL_ID('sre_fault_runner') IS NULL
          CREATE USER [sre_fault_runner] WITH PASSWORD = '${faultRunnerPassword}';
        ELSE
          ALTER USER [sre_fault_runner] WITH PASSWORD = '${faultRunnerPassword}';
        GRANT SELECT, UPDATE ON OBJECT::dbo.SreFaultLocks TO [sre_fault_runner];
      `);
    }
    const { recordset } = await connection.request().query('SELECT COUNT(*) AS cnt FROM Items');
    if (recordset[0].cnt < 10) {
      const values = [];
      for (let index = 0; index < 100; index += 1) {
        values.push(`('item-${index}', 'active', DATEADD(SECOND, -${index}, SYSUTCDATETIME()))`);
      }
      await connection.request().query(`INSERT INTO Items (Name, Status, CreatedAt) VALUES ${values.join(',')}`);
      console.log('Seeded 100 sample items');
    }
    console.log('Database initialised');
  } catch (err) {
    console.error('Database initialisation skipped:', err.message);
  }
}

function delay(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

async function fetchItems() {
  const connection = await getPool();
  if (!faultAdapter.isActive('app-n-plus-one')) {
    return (await connection.request().query('SELECT TOP 50 * FROM Items ORDER BY CreatedAt DESC')).recordset;
  }

  const { recordset: itemIds } = await connection.request()
    .query('SELECT TOP 50 Id FROM Items ORDER BY CreatedAt DESC');
  const items = [];
  for (const item of itemIds) {
    const detail = await connection.request().input('id', sql.Int, item.Id)
      .query('SELECT * FROM Items WHERE Id = @id');
    if (detail.recordset[0]) items.push(detail.recordset[0]);
  }
  return items;
}

function operationIdFrom(req) {
  const supplied = req.get('x-operation-id');
  return supplied && /^[A-Za-z0-9_.:-]{1,128}$/.test(supplied) ? supplied : randomUUID();
}

async function recordUser(req, operationType, startedAt, success, detail) {
  await activityWriter.write({
    operationId: operationIdFrom(req), source: 'USER', operationType, success,
    durationMs: Date.now() - startedAt, detail,
  });
}

let workload;

function createApp() {
  const app = express();
  app.use(express.json());
  app.use(express.static(path.join(__dirname, '..', 'public')));

  app.get('/api/status', async (_req, res) => {
    let dbConnected = false;
    let itemCount = null;
    try {
      const result = await (await getPool()).request().query('SELECT COUNT(*) AS cnt FROM Items');
      dbConnected = true;
      itemCount = result.recordset[0].cnt;
    } catch (_) { /* Keep status available during database faults. */ }
    const recentActivities = activityWriter.getRecent();
    res.json({
      dbConnected, itemCount,
      workload: { state: workload?.isRunning() ? 'running' : 'stopped' },
      recentActivities,
      log: recentActivities.map(event => ({
        time: event.timestamp, type: event.operationType, detail: event.detail,
        durationMs: event.durationMs, success: event.success, source: event.source,
      })),
    });
  });

  app.get('/health', (_req, res) => res.json({ status: 'healthy', uptime: process.uptime() }));
  app.get('/ready', async (_req, res) => {
    try {
      await (await getPool()).request().query('SELECT 1');
      res.json({ status: 'ready', db: 'connected' });
    } catch (err) {
      console.error('/ready check failed:', err.message);
      res.status(503).json({ status: 'not ready', db: 'connection failed' });
    }
  });

  app.get('/api/items', async (req, res) => {
    const startedAt = Date.now();
    const isAuto = req.get('x-sre-activity-source') === 'AUTO';
    try {
      if (faultAdapter.isActive('app-exception')) throw new Error('Injected app-exception fault');
      const latencyMs = faultAdapter.getLatencyMs();
      if (latencyMs > 0) await delay(latencyMs);
      const items = await fetchItems();
      if (!isAuto) await recordUser(req, 'READ', startedAt, true, `${items.length} items fetched`);
      res.json(items);
    } catch (err) {
      console.error('GET /api/items error:', err.message);
      if (!isAuto) await recordUser(req, 'READ', startedAt, false, err.message);
      res.status(500).json({ error: 'Internal server error' });
    }
  });

  app.post('/api/items', async (req, res) => {
    const startedAt = Date.now();
    const name = typeof req.body.name === 'string' ? req.body.name.trim() : '';
    if (!name || name.length > 200) {
      await recordUser(req, 'CREATE', startedAt, false, 'invalid name');
      return res.status(400).json({ error: 'name is required and must be at most 200 characters' });
    }
    try {
      const result = await (await getPool()).request().input('name', sql.NVarChar(200), name)
        .query('INSERT INTO Items (Name) OUTPUT INSERTED.* VALUES (@name)');
      await recordUser(req, 'CREATE', startedAt, true, `Item #${result.recordset[0].Id} created`);
      return res.status(201).json(result.recordset[0]);
    } catch (err) {
      console.error('POST /api/items error:', err.message);
      await recordUser(req, 'CREATE', startedAt, false, err.message);
      return res.status(500).json({ error: 'Internal server error' });
    }
  });

  app.put('/api/items/:id', async (req, res) => {
    const startedAt = Date.now();
    const id = Number.parseInt(req.params.id, 10);
    const status = typeof req.body.status === 'string' ? req.body.status.trim() : '';
    if (!Number.isInteger(id) || id <= 0 || !status || status.length > 50) {
      await recordUser(req, 'UPDATE', startedAt, false, 'invalid id or status');
      return res.status(400).json({ error: 'valid id and status are required' });
    }
    try {
      const result = await (await getPool()).request().input('id', sql.Int, id)
        .input('status', sql.NVarChar(50), status)
        .query('UPDATE Items SET Status = @status OUTPUT INSERTED.* WHERE Id = @id');
      if (result.recordset.length === 0) {
        await recordUser(req, 'UPDATE', startedAt, false, `Item #${id} not found`);
        return res.status(404).json({ error: 'Item not found' });
      }
      await recordUser(req, 'UPDATE', startedAt, true, `Item #${id} updated to ${status}`);
      return res.json(result.recordset[0]);
    } catch (err) {
      console.error('PUT /api/items error:', err.message);
      await recordUser(req, 'UPDATE', startedAt, false, err.message);
      return res.status(500).json({ error: 'Internal server error' });
    }
  });

  app.delete('/api/items/:id', async (req, res) => {
    const startedAt = Date.now();
    const id = Number.parseInt(req.params.id, 10);
    if (!Number.isInteger(id) || id <= 0) {
      await recordUser(req, 'DELETE', startedAt, false, 'invalid id');
      return res.status(400).json({ error: 'valid id is required' });
    }
    try {
      const result = await (await getPool()).request().input('id', sql.Int, id)
        .query('DELETE FROM Items WHERE Id = @id');
      if (result.rowsAffected[0] === 0) {
        await recordUser(req, 'DELETE', startedAt, false, `Item #${id} not found`);
        return res.status(404).json({ error: 'Item not found' });
      }
      await recordUser(req, 'DELETE', startedAt, true, `Item #${id} deleted`);
      return res.status(204).end();
    } catch (err) {
      console.error('DELETE /api/items error:', err.message);
      await recordUser(req, 'DELETE', startedAt, false, err.message);
      return res.status(500).json({ error: 'Internal server error' });
    }
  });
  return app;
}

workload = createWorkload({
  activityWriter,
  read: async () => {
    const response = await fetch(`http://localhost:${PORT}/api/items`, {
      headers: { 'x-sre-activity-source': 'AUTO' },
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return `${(await response.json()).length} items fetched`;
  },
  write: async () => {
    const connection = await getPool();
    const { recordset } = await connection.request()
      .query('SELECT TOP 1 Id, Status FROM Items ORDER BY NEWID()');
    if (recordset.length === 0) return 'No items available';
    const item = recordset[0];
    const newStatus = String(item.Status).toLowerCase() === 'active' ? 'processed' : 'active';
    await connection.request().input('id', sql.Int, item.Id)
      .input('status', sql.NVarChar(50), newStatus)
      .query('UPDATE Items SET Status = @status WHERE Id = @id');
    return `Item #${item.Id} updated to ${newStatus}`;
  },
});

async function start() {
  const server = createApp().listen(PORT, async () => {
    console.log(`Server listening on port ${PORT}`);
    await initDb();
    faultAdapter.start();
    workload.start();
  });
  const shutdown = async () => {
    workload.stop();
    faultAdapter.stop();
    server.close();
    try { await closePool(); } catch (err) { console.error('Pool close error:', err.message); }
  };
  process.once('SIGTERM', shutdown);
  process.once('SIGINT', shutdown);
  return server;
}

const poolResetTimer = setInterval(() => {
  closePool().catch(err => console.error('Pool close error:', err.message));
}, 300000);
poolResetTimer.unref();

if (require.main === module) void start();
module.exports = { createApp, fetchItems, getPool, initDb, start };
