'use strict';

const DEMO_OPERATOR = Object.freeze({ userId: 'demo-operator', name: 'Demo operator' });

function createAuthorization() {

  function authenticate(req, res, next) {
    req.principal = DEMO_OPERATOR;
    return next();
  }

  function requireSameOrigin(req, res, next) {
    const origin = req.get('Origin');
    const forwardedHost = req.get('X-Forwarded-Host');
    const host = forwardedHost || req.get('Host');
    if (!origin || !host) return res.status(403).json({ error: 'Same-origin request required' });
    try {
      if (new URL(origin).host !== host) return res.status(403).json({ error: 'Same-origin request required' });
    } catch (_) {
      return res.status(403).json({ error: 'Same-origin request required' });
    }
    return next();
  }

  return { authenticate, requireSameOrigin };
}

module.exports = { createAuthorization, DEMO_OPERATOR };