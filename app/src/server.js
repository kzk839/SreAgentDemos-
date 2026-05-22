'use strict';

// Application Insights (must be initialized before other imports)
if (process.env.APPLICATIONINSIGHTS_CONNECTION_STRING) {
  const appInsights = require('applicationinsights');
  appInsights
    .setup(process.env.APPLICATIONINSIGHTS_CONNECTION_STRING)
    .setAutoCollectRequests(true)
    .setAutoCollectPerformance(true)
    .setAutoCollectExceptions(true)
    .setAutoCollectDependencies(true)
    .start();

  // Exclude health probes from telemetry to avoid diluting response-time metrics
  appInsights.defaultClient.addTelemetryProcessor((envelope) => {
    if (envelope.data && envelope.data.baseData) {
      const name = envelope.data.baseData.name || '';
      if (name.includes('/health') || name.includes('/ready')) {
        return false; // drop this telemetry
      }
    }
    return true;
  });
}

const express = require('express');
const sql = require('mssql');

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 8080;

// ---------------------------------------------------------------------------
// SQL connection
// ---------------------------------------------------------------------------
const sqlConfig = {
  connectionString: process.env.SQL_CONNECTION_STRING,
  pool: { max: 10, min: 0, idleTimeoutMillis: 30000 },
};

let pool = null;

async function getPool() {
  if (!pool) {
    if (!sqlConfig.connectionString) {
      throw new Error('SQL_CONNECTION_STRING is not configured');
    }
    pool = await sql.connect(sqlConfig.connectionString);
  }
  return pool;
}

// ---------------------------------------------------------------------------
// DB initialisation (create table if not exists)
// ---------------------------------------------------------------------------
async function initDb() {
  try {
    const p = await getPool();
    await p.request().query(`
      IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Items')
      CREATE TABLE Items (
        Id INT IDENTITY(1,1) PRIMARY KEY,
        Name NVARCHAR(200) NOT NULL,
        Status NVARCHAR(50) NOT NULL DEFAULT 'active',
        CreatedAt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
      )
    `);
    console.log('Database initialised');
  } catch (err) {
    console.error('Database initialisation skipped:', err.message);
  }
}

// ---------------------------------------------------------------------------
// Health / Readiness
// ---------------------------------------------------------------------------
app.get('/health', (_req, res) => {
  res.json({ status: 'healthy', uptime: process.uptime() });
});

app.get('/ready', async (_req, res) => {
  try {
    const p = await getPool();
    await p.request().query('SELECT 1');
    res.json({ status: 'ready', db: 'connected' });
  } catch (err) {
    console.error('/ready check failed:', err);
    res.status(503).json({ status: 'not ready', db: 'connection failed' });
  }
});

// ---------------------------------------------------------------------------
// CRUD - /api/items
// ---------------------------------------------------------------------------

// ===========================================================================
// BUG SCENARIO A: アプリケーションバグ（例外）
// コメントを外すとデプロイ後に全 GET /api/items で例外が発生します。
// アラート: app-exceptions, app-failed-requests
// 調査ポイント: App Insights のスタックトレース、デプロイタイミングとの相関
// ---------------------------------------------------------------------------
// app.get('/api/items', (_req, _res) => {
//   // 開発者の意図しない undefined 参照（レビュー漏れを想定）
//   const config = undefined;
//   const items = config.getItems();  // TypeError: Cannot read properties of undefined
//   _res.json(items);
// });
// ===========================================================================

// ===========================================================================
// BUG SCENARIO B: データベースパフォーマンス劣化
// コメントを外すと N+1 クエリ + 重負荷集計が発生し DTU が枯渇します。
// アラート: sql-dtu-high, sql-deadlock
// 調査ポイント: SQL メトリクス急増、App Insights 依存関係テレメトリ
// ---------------------------------------------------------------------------
// app.get('/api/items', async (req, res) => {
//   try {
//     const p = await getPool();
//     // N+1 クエリ: 全件取得後に1件ずつ再取得（非効率パターン）
//     const { recordset: ids } = await p.request().query('SELECT Id FROM Items');
//     const items = [];
//     for (const row of ids) {
//       const detail = await p.request().query(
//         `SELECT * FROM Items WITH (HOLDLOCK) WHERE Id = ${row.Id};
//          WAITFOR DELAY '00:00:01';`
//       );
//       items.push(detail.recordset[0]);
//     }
//     // 追加の重負荷集計クエリ
//     await p.request().query(`
//       DECLARE @i INT = 0;
//       WHILE @i < 500000 BEGIN SET @i = @i + 1; END;
//       SELECT COUNT(*) AS total FROM Items CROSS JOIN Items AS t2;
//     `);
//     res.json(items);
//   } catch (err) {
//     res.status(500).json({ error: err.message });
//   }
// });
// ===========================================================================

// 正常版（バグシナリオ使用時はこの関数をコメントアウトしてください）
app.get('/api/items', async (_req, res) => {
  try {
    const p = await getPool();
    const result = await p.request().query('SELECT * FROM Items ORDER BY CreatedAt DESC');
    res.json(result.recordset);
  } catch (err) {
    console.error('GET /api/items error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

app.post('/api/items', async (req, res) => {
  try {
    const { name } = req.body;
    if (!name) return res.status(400).json({ error: 'name is required' });
    const p = await getPool();
    const result = await p
      .request()
      .input('name', sql.NVarChar(200), name)
      .query('INSERT INTO Items (Name) OUTPUT INSERTED.* VALUES (@name)');
    res.status(201).json(result.recordset[0]);
  } catch (err) {
    console.error('POST /api/items error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

app.delete('/api/items/:id', async (req, res) => {
  try {
    const p = await getPool();
    await p
      .request()
      .input('id', sql.Int, parseInt(req.params.id, 10))
      .query('DELETE FROM Items WHERE Id = @id');
    res.status(204).end();
  } catch (err) {
    console.error('DELETE /api/items error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ---------------------------------------------------------------------------
// Chaos Engineering Endpoints - /chaos/*
// WARNING: These endpoints intentionally cause failures for SRE demo purposes.
//          Protected by ENABLE_CHAOS environment variable.
// ---------------------------------------------------------------------------
const chaosEnabled = process.env.ENABLE_CHAOS === 'true';

app.use('/chaos', (req, res, next) => {
  if (!chaosEnabled) {
    return res.status(403).json({ error: 'Chaos endpoints are disabled. Set ENABLE_CHAOS=true to enable.' });
  }
  next();
});

// CPU spike: burn CPU for N seconds (default 10)
app.post('/chaos/cpu', (req, res) => {
  const seconds = Math.min(parseInt(req.body.seconds) || 10, 60);
  console.warn(`[CHAOS] CPU spike for ${seconds}s`);
  const end = Date.now() + seconds * 1000;
  // Intentional busy loop for chaos simulation
  while (Date.now() < end) {
    Math.random() * Math.random();
  }
  res.json({ chaos: 'cpu', duration: seconds, status: 'completed' });
});

// Memory pressure: allocate N MB (default 100), hold for N seconds
app.post('/chaos/memory', (req, res) => {
  const mb = Math.min(parseInt(req.body.mb) || 100, 512);
  const holdSeconds = Math.min(parseInt(req.body.seconds) || 30, 120);
  console.warn(`[CHAOS] Memory pressure: ${mb}MB for ${holdSeconds}s`);
  const buffers = [];
  for (let i = 0; i < mb; i++) {
    buffers.push(Buffer.alloc(1024 * 1024, 'x'));
  }
  setTimeout(() => {
    buffers.length = 0;
    if (global.gc) global.gc();
  }, holdSeconds * 1000);
  res.json({ chaos: 'memory', mb, holdSeconds, status: 'holding' });
});

// Latency injection: add N ms delay to all subsequent requests for N seconds
let latencyMs = 0;
let latencyUntil = 0;
app.use((req, _res, next) => {
  if (latencyMs > 0 && Date.now() < latencyUntil) {
    setTimeout(next, latencyMs);
  } else {
    latencyMs = 0;
    next();
  }
});
app.post('/chaos/latency', (req, res) => {
  latencyMs = Math.min(parseInt(req.body.ms) || 3000, 30000);
  const seconds = Math.min(parseInt(req.body.seconds) || 60, 3600);
  latencyUntil = Date.now() + seconds * 1000;
  console.warn(`[CHAOS] Latency injection: ${latencyMs}ms for ${seconds}s`);
  res.json({ chaos: 'latency', ms: latencyMs, seconds, status: 'active' });
});

// Error injection: return 500 for all requests for N seconds
let errorUntil = 0;
app.post('/chaos/error', (req, res) => {
  const seconds = Math.min(parseInt(req.body.seconds) || 60, 3600);
  errorUntil = Date.now() + seconds * 1000;
  console.warn(`[CHAOS] Error injection for ${seconds}s`);
  res.json({ chaos: 'error', seconds, status: 'active' });
});
app.use((req, res, next) => {
  if (Date.now() < errorUntil && !req.path.startsWith('/chaos') && req.path !== '/health') {
    return res.status(500).json({ error: 'Simulated server error (chaos)' });
  }
  next();
});

// DB load: run expensive queries
app.post('/chaos/db-load', async (req, res) => {
  const iterations = Math.min(parseInt(req.body.iterations) || 10, 100);
  console.warn(`[CHAOS] DB load: ${iterations} heavy queries`);
  try {
    const p = await getPool();
    const promises = [];
    for (let i = 0; i < iterations; i++) {
      promises.push(
        p.request().query(`
          DECLARE @i INT = 0;
          WHILE @i < 100000 BEGIN SET @i = @i + 1; END;
          SELECT @i AS Result;
        `)
      );
    }
    await Promise.all(promises);
    res.json({ chaos: 'db-load', iterations, status: 'completed' });
  } catch (err) {
    res.status(500).json({ chaos: 'db-load', error: err.message });
  }
});

// Reset all chaos
app.post('/chaos/reset', (_req, res) => {
  latencyMs = 0;
  latencyUntil = 0;
  errorUntil = 0;
  console.warn('[CHAOS] All chaos effects reset');
  res.json({ chaos: 'reset', status: 'all cleared' });
});

// Chaos status
app.get('/chaos/status', (_req, res) => {
  const now = Date.now();
  res.json({
    latency: now < latencyUntil ? { active: true, ms: latencyMs, remainingSeconds: Math.ceil((latencyUntil - now) / 1000) } : { active: false },
    error: now < errorUntil ? { active: true, remainingSeconds: Math.ceil((errorUntil - now) / 1000) } : { active: false },
  });
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------
app.listen(PORT, async () => {
  console.log(`Server listening on port ${PORT}`);
  await initDb();
});
