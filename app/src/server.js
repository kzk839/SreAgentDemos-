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

    // シードデータ: アイテムが 100 件未満なら 10,000 件のサンプルデータを投入
    const { recordset } = await p.request().query('SELECT COUNT(*) AS cnt FROM Items');
    if (recordset[0].cnt < 100) {
      // バッチ INSERT（1,000 件 × 10 バッチ）
      for (let batch = 0; batch < 10; batch++) {
        const values = [];
        for (let i = 0; i < 1000; i++) {
          const idx = batch * 1000 + i;
          values.push(`('item-${idx}', 'active', DATEADD(SECOND, -${idx}, SYSUTCDATETIME()))`);
        }
        await p.request().query(`INSERT INTO Items (Name, Status, CreatedAt) VALUES ${values.join(',')}`);
      }
      console.log('Seeded 10,000 sample items');
    }

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
app.get('/api/items', (_req, _res) => {
  // 開発者の意図しない undefined 参照（レビュー漏れを想定）
  const config = undefined;
  const items = config.getItems();  // TypeError: Cannot read properties of undefined
  _res.json(items);
});
// ===========================================================================

// ===========================================================================
// BUG SCENARIO B: N+1 クエリによるレスポンス遅延
// コメントを外すと全件取得後に1件ずつ詳細を再取得する N+1 パターンが発生します。
// アラート: app-slow-response
// 調査ポイント: App Insights 依存関係テレメトリでの SQL 呼び出し数急増、デプロイ相関
// ---------------------------------------------------------------------------
// app.get('/api/items', async (req, res) => {
//   try {
//     const p = await getPool();
//     // N+1 クエリ: 全件取得後に1件ずつ再取得（よくあるORMの誤用パターン）
//     const { recordset: allItems } = await p.request()
//       .query('SELECT Id FROM Items ORDER BY CreatedAt DESC');
//     const items = [];
//     for (const row of allItems) {
//       const detail = await p.request()
//         .input('id', row.Id)
//         .query('SELECT * FROM Items WHERE Id = @id');
//       items.push(detail.recordset[0]);
//     }
//     res.json(items);
//   } catch (err) {
//     console.error('GET /api/items error:', err);
//     res.status(500).json({ error: 'Internal server error' });
//   }
// });
// ===========================================================================

// 正常版（バグシナリオ使用時はこの関数をコメントアウトしてください）
// app.get('/api/items', async (_req, res) => {
//   try {
//     const p = await getPool();
//     const result = await p.request().query('SELECT TOP 50 * FROM Items ORDER BY CreatedAt DESC');
//     res.json(result.recordset);
//   } catch (err) {
//     console.error('GET /api/items error:', err);
//     res.status(500).json({ error: 'Internal server error' });
//   }
// });

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
// Start
// ---------------------------------------------------------------------------
app.listen(PORT, async () => {
  console.log(`Server listening on port ${PORT}`);
  await initDb();
});
