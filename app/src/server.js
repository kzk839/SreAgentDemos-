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
// Activity log (ring buffer for dashboard)
// ---------------------------------------------------------------------------
const ACTIVITY_LOG_MAX = 50;
const activityLog = [];

function logActivity(type, detail, durationMs, success) {
  activityLog.unshift({
    time: new Date().toISOString(),
    type,
    detail,
    durationMs,
    success,
  });
  if (activityLog.length > ACTIVITY_LOG_MAX) activityLog.pop();
}

// ---------------------------------------------------------------------------
// SQL connection
// ---------------------------------------------------------------------------
const sqlConfig = {
  connectionString: process.env.SQL_CONNECTION_STRING,
  pool: { max: 10, min: 0, idleTimeoutMillis: 30000 },
};

let pool = null;
let poolUseCount = 0;
const POOL_RESET_INTERVAL = 10; // 10回使用ごとにプールをリセット

async function getPool() {
  if (!pool) {
    if (!sqlConfig.connectionString) {
      throw new Error('SQL_CONNECTION_STRING is not configured');
    }
    pool = await sql.connect(sqlConfig.connectionString);
    poolUseCount = 0;
  }
  poolUseCount++;
  if (poolUseCount >= POOL_RESET_INTERVAL) {
    const oldPool = pool;
    pool = null;
    poolUseCount = 0;
    oldPool.close().catch(err => console.error('Pool close error:', err.message));
  }
  return pool || await sql.connect(sqlConfig.connectionString);
}

// poolUseCount 未到達でも長時間アイドル時に備えて、5分ごとにもリセット
setInterval(async () => {
  if (pool) {
    const oldPool = pool;
    pool = null;
    try {
      await oldPool.close();
    } catch (err) {
      console.error('Pool close error:', err.message);
    }
  }
}, 300000); // 5分

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

    // シードデータ: アイテムが 100 件未満なら 1,000 件のサンプルデータを投入
    const { recordset } = await p.request().query('SELECT COUNT(*) AS cnt FROM Items');
    if (recordset[0].cnt < 100) {
      const values = [];
      for (let i = 0; i < 1000; i++) {
        values.push(`('item-${i}', 'active', DATEADD(SECOND, -${i}, SYSUTCDATETIME()))`);
      }
      await p.request().query(`INSERT INTO Items (Name, Status, CreatedAt) VALUES ${values.join(',')}`);
      console.log('Seeded 1,000 sample items');
    }

    console.log('Database initialised');
  } catch (err) {
    console.error('Database initialisation skipped:', err.message);
  }
}

// ---------------------------------------------------------------------------
// Dashboard
// ---------------------------------------------------------------------------
app.get('/', (_req, res) => {
  res.send(`<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>SRE Demo App</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: 'Segoe UI', system-ui, sans-serif; background: #1a1a2e; color: #e0e0e0; padding: 24px; }
    h1 { font-size: 1.4rem; margin-bottom: 16px; color: #00d4ff; }
    .stats { display: flex; gap: 16px; margin-bottom: 20px; }
    .stat { background: #16213e; border-radius: 8px; padding: 12px 20px; }
    .stat .label { font-size: 0.75rem; color: #888; text-transform: uppercase; }
    .stat .value { font-size: 1.5rem; font-weight: bold; }
    .stat .value.ok { color: #00e676; }
    .stat .value.err { color: #ff5252; }
    table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
    th { text-align: left; padding: 8px; border-bottom: 1px solid #333; color: #888; font-weight: 500; }
    td { padding: 6px 8px; border-bottom: 1px solid #222; }
    tr.ok td:last-child { color: #00e676; }
    tr.err td:last-child { color: #ff5252; font-weight: bold; }
    .type { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 0.75rem; font-weight: bold; }
    .type.READ { background: #1b5e20; }
    .type.WRITE { background: #e65100; }
    .type.API { background: #1565c0; }
    .footer { margin-top: 16px; font-size: 0.75rem; color: #555; }
  </style>
</head>
<body>
  <h1>⚡ SRE Demo App - Live Dashboard</h1>
  <div class="stats">
    <div class="stat"><div class="label">DB Pool</div><div class="value" id="pool">-</div></div>
    <div class="stat"><div class="label">Items</div><div class="value" id="items">-</div></div>
    <div class="stat"><div class="label">Success Rate</div><div class="value" id="rate">-</div></div>
    <div class="stat"><div class="label">Read Avg</div><div class="value" id="readAvg">-</div></div>
    <div class="stat"><div class="label">Write Avg</div><div class="value" id="writeAvg">-</div></div>
  </div>
  <table>
    <thead><tr><th>Time (JST)</th><th>Type</th><th>Detail</th><th>Duration</th><th>Status</th></tr></thead>
    <tbody id="log"></tbody>
  </table>
  <div class=\"footer\">Next refresh in <span id=\"countdown\">3</span>s</div>
  <script>
    async function refresh() {
      try {
        const r = await fetch('/api/status');
        const d = await r.json();
        document.getElementById('pool').textContent = d.dbConnected ? 'Connected' : 'Disconnected';
        document.getElementById('pool').className = 'value ' + (d.dbConnected ? 'ok' : 'err');
        document.getElementById('items').textContent = d.itemCount ?? '-';
        const total = d.log.length || 1;
        const ok = d.log.filter(e => e.success).length;
        const pct = Math.round(ok / total * 100);
        const rateEl = document.getElementById('rate');
        rateEl.textContent = pct + '%';
        rateEl.className = 'value ' + (pct >= 80 ? 'ok' : 'err');
        function calcAvg(type) {
          const items = d.log.filter(e => e.type === type && e.success && e.durationMs != null);
          if (items.length === 0) return null;
          return Math.round(items.reduce((s, e) => s + e.durationMs, 0) / items.length);
        }
        const ra = calcAvg('READ'), wa = calcAvg('WRITE');
        const readEl = document.getElementById('readAvg');
        readEl.textContent = ra != null ? ra + 'ms' : '-';
        readEl.className = 'value ' + (ra == null || ra > 2000 ? 'err' : 'ok');
        const writeEl = document.getElementById('writeAvg');
        writeEl.textContent = wa != null ? wa + 'ms' : '-';
        writeEl.className = 'value ' + (wa == null || wa > 2000 ? 'err' : 'ok');
        document.getElementById('log').innerHTML = d.log.map(e => {
          const t = new Date(e.time).toLocaleTimeString('ja-JP', {timeZone:'Asia/Tokyo'});
          const cls = e.success ? 'ok' : 'err';
          const dur = e.durationMs != null ? e.durationMs + 'ms' : '-';
          const status = e.success ? '\u2705' : '\u274c';
          return '<tr class="' + cls + '"><td>' + t + '</td><td><span class="type ' + e.type + '">' + e.type + '</span></td><td>' + e.detail + '</td><td>' + dur + '</td><td>' + status + '</td></tr>';
        }).join('');
      } catch (e) { console.error('Dashboard fetch error:', e); }
    }
    let countdown = 3;
    function tick() {
      document.getElementById('countdown').textContent = countdown;
      if (countdown <= 0) { refresh(); countdown = 3; }
      else { countdown--; }
    }
    refresh();
    setInterval(tick, 1000);
  </script>
</body>
</html>`);
});

app.get('/api/status', async (_req, res) => {
  let dbConnected = false;
  let itemCount = null;
  try {
    const p = await getPool();
    const r = await p.request().query('SELECT COUNT(*) AS cnt FROM Items');
    dbConnected = true;
    itemCount = r.recordset[0].cnt;
  } catch (_) { /* DB unreachable */ }
  res.json({ dbConnected, itemCount, log: activityLog });
});

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
// async function fetchItems() {
//   // 開発者の意図しない undefined 参照（レビュー漏れを想定）
//   const config = undefined;
//   return config.getItems();  // TypeError: Cannot read properties of undefined
// }
// ===========================================================================

// ===========================================================================
// BUG SCENARIO B: N+1 クエリによるレスポンス遅延
// コメントを外すと全件取得後に1件ずつ詳細を再取得する N+1 パターンが発生します。
// アラート: app-slow-response
// 調査ポイント: App Insights 依存関係テレメトリでの SQL 呼び出し数急増、デプロイ相関
// ---------------------------------------------------------------------------
// async function fetchItems() {
//   const p = await getPool();
//   // N+1 クエリ: 全件取得後に1件ずつ再取得（よくあるORMの誤用パターン）
//   const { recordset: allItems } = await p.request()
//     .query('SELECT Id FROM Items ORDER BY CreatedAt DESC');
//   const items = [];
//   for (const row of allItems) {
//     const detail = await p.request()
//       .input('id', row.Id)
//       .query('SELECT * FROM Items WHERE Id = @id');
//     items.push(detail.recordset[0]);
//   }
//   return items;
// }
// ===========================================================================

// 正常版（バグシナリオ使用時はこの関数をコメントアウトしてください）
async function fetchItems() {
  const p = await getPool();
  const result = await p.request().query('SELECT TOP 50 * FROM Items ORDER BY CreatedAt DESC');
  return result.recordset;
}

app.get('/api/items', async (_req, res) => {
  try {
    const items = await fetchItems();
    res.json(items);
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
// Background worker: 業務処理シミュレーション（ランダム間隔で READ / WRITE）
// ---------------------------------------------------------------------------

// READ: 10〜30秒ごとに自身の /api/items を HTTP で呼び出し（App Insights に記録される）
function scheduleRead() {
  const delay = (Math.floor(Math.random() * 21) + 10) * 1000;
  setTimeout(async () => {
    const start = Date.now();
    try {
      const res = await fetch(`http://localhost:${PORT}/api/items`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const items = await res.json();
      logActivity('READ', `${items.length} items fetched`, Date.now() - start, true);
    } catch (err) {
      console.error('BG read error:', err.message);
      logActivity('READ', err.message, null, false);
    }
    scheduleRead();
  }, delay);
}

// WRITE: 15〜45秒ごとにランダムなアイテムのステータスを更新
function scheduleWrite() {
  const delay = (Math.floor(Math.random() * 31) + 15) * 1000;
  setTimeout(async () => {
    const start = Date.now();
    try {
      const p = await getPool();
      const { recordset } = await p.request()
        .query('SELECT TOP 1 Id, Status FROM Items ORDER BY NEWID()');
      if (recordset.length > 0) {
        const item = recordset[0];
        const newStatus = item.Status === 'Active' ? 'Processed' : 'Active';
        await p.request()
          .input('id', sql.Int, item.Id)
          .input('status', sql.NVarChar(50), newStatus)
          .query('UPDATE Items SET Status = @status WHERE Id = @id');
        logActivity('WRITE', `Item #${item.Id} → ${newStatus}`, Date.now() - start, true);
      }
    } catch (err) {
      console.error('BG write error:', err.message);
      logActivity('WRITE', err.message, null, false);
    }
    scheduleWrite();
  }, delay);
}

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------
app.listen(PORT, async () => {
  console.log(`Server listening on port ${PORT}`);
  await initDb();
  scheduleRead();
  scheduleWrite();
});
