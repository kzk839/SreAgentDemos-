'use strict';

const path = require('node:path');
const express = require('express');
const { createAuthorization } = require('./auth');

function requireBodyKeys(allowedKeys) {
  return (req, res, next) => {
    const body = req.body && typeof req.body === 'object' && !Array.isArray(req.body) ? req.body : {};
    if (Object.keys(body).some(key => !allowedKeys.includes(key))) {
      return res.status(400).json({ error: 'Unsupported request field' });
    }
    return next();
  };
}

function createApp(options) {
  const app = express();
  const authorization = createAuthorization();
  const mutationsEnabled = options.mutationsEnabled === true;

  app.disable('x-powered-by');
  app.set('trust proxy', 1);
  app.use(express.json({ limit: '16kb' }));
  app.use(express.static(path.join(__dirname, '..', 'public')));
  app.get('/vendor/chart.umd.js', (_req, res) => res.sendFile(path.join(path.dirname(require.resolve('chart.js')), 'chart.umd.js')));
  app.get('/health', (_req, res) => res.json({ status: 'ok' }));

  app.use('/api', authorization.authenticate);
  app.get('/api/dashboard', async (req, res, next) => {
    try { res.json(await options.activityStore.dashboard(req.query)); } catch (error) { next(error); }
  });
  app.get('/api/faults', async (_req, res, next) => {
    try { res.json({ faults: await options.faultController.list() }); } catch (error) { next(error); }
  });

  app.use('/api', authorization.requireSameOrigin, (req, res, next) => {
    if (!mutationsEnabled) return res.status(503).json({ error: 'Fault injection is disabled' });
    return next();
  });
  app.post('/api/faults/emergency-stop', requireBodyKeys([]), async (req, res, next) => {
    try { res.json({ faults: await options.faultController.stopAll(req.principal.userId) }); } catch (error) { next(error); }
  });
  app.post('/api/faults/:id/start', requireBodyKeys(['parameters']), async (req, res, next) => {
    try { res.json(await options.faultController.start(req.params.id, req.principal.userId, req.body?.parameters)); } catch (error) { next(error); }
  });
  app.post('/api/faults/:id/stop', requireBodyKeys([]), async (req, res, next) => {
    try { res.json(await options.faultController.stop(req.params.id, req.principal.userId)); } catch (error) { next(error); }
  });
  app.post('/api/reset', requireBodyKeys([]), async (req, res, next) => {
    try {
      const faults = await options.faultController.stopAll(req.principal.userId);
      await options.activityStore.clear();
      await options.auditStore?.write({ action: 'reset', requestedBy: req.principal.userId, result: 'requested' });
      res.json({ faults, activityEventsCleared: true, auditPreserved: true });
    } catch (error) { next(error); }
  });

  app.use((error, _req, res, _next) => {
    const status = error.statusCode || (error instanceof TypeError ? 400 : 503);
    res.status(status).json({ error: status >= 500 ? 'Control store unavailable' : error.message });
  });
  return app;
}

module.exports = { createApp, requireBodyKeys };