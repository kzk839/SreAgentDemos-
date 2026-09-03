'use strict';

const ROLE_CLAIM_TYPES = new Set(['roles', 'role', 'http://schemas.microsoft.com/ws/2008/06/identity/claims/role']);
const ID_CLAIM_TYPES = new Set(['oid', 'http://schemas.microsoft.com/identity/claims/objectidentifier']);
const NAME_CLAIM_TYPES = new Set(['name', 'preferred_username', 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name']);

function parsePrincipal(encoded) {
  if (!encoded) return null;
  try {
    const value = JSON.parse(Buffer.from(encoded, 'base64').toString('utf8'));
    if (!value || !Array.isArray(value.claims)) return null;
    const claims = value.claims.filter(claim => claim && typeof claim.typ === 'string');
    const roles = claims.filter(claim => ROLE_CLAIM_TYPES.has(claim.typ)).map(claim => claim.val);
    const findClaim = types => claims.find(claim => types.has(claim.typ))?.val;
    return {
      userId: findClaim(ID_CLAIM_TYPES) || value.userId || value.userDetails || 'unknown',
      name: findClaim(NAME_CLAIM_TYPES) || value.userDetails || 'Unknown user',
      roles: [...new Set(roles)],
    };
  } catch (_) {
    return null;
  }
}

function createAuthorization(options = {}) {
  const disabled = options.disabled === true;

  function authenticate(req, res, next) {
    const principal = disabled
      ? { userId: 'local-development', name: 'Local development', roles: ['Reader', 'Operator'] }
      : parsePrincipal(req.get('X-MS-CLIENT-PRINCIPAL'));
    if (!principal) return res.status(401).json({ error: 'Authentication required' });
    req.principal = principal;
    return next();
  }

  function requireRole(role) {
    return (req, res, next) => {
      const hasRole = req.principal.roles.includes(role)
        || (role === 'Reader' && req.principal.roles.includes('Operator'));
      if (!hasRole) return res.status(403).json({ error: `${role} role required` });
      return next();
    };
  }

  function requireSameOrigin(req, res, next) {
    if (disabled) return next();
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

  return { authenticate, requireRole, requireSameOrigin };
}

module.exports = { createAuthorization, parsePrincipal };