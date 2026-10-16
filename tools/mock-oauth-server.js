#!/usr/bin/env node
'use strict';

// ---------------------------------------------------------------------------
// Local stand-in for the Bijira key manager + a gateway-protected API, so the
// JS client and JMeter plan can be exercised before real endpoints/credentials
// are available. NOT a real OAuth server — auto-approves every /authorize.
//
//   node mock-oauth-server.js            (listens on http://localhost:9443)
//
// Endpoints:
//   GET  /oauth2/authorize   auto-approves, redirects to redirect_uri with code
//   POST /oauth2/token       client_credentials | authorization_code (+PKCE) | refresh_token
//   GET  /oauth2/jwks        RS256 public key
//   ANY  /api/*              validates the Bearer JWT, logs the correlation ID
//                            (like a Devant log line), echoes request details
// ---------------------------------------------------------------------------

const http = require('http');
const crypto = require('crypto');

const PORT = Number(process.env.PORT || 9443);
const ISSUER = `http://localhost:${PORT}/oauth2/token`;
const CLIENT_ID = process.env.MOCK_CLIENT_ID || 'test-client';
const CLIENT_SECRET = process.env.MOCK_CLIENT_SECRET || 'test-secret';
const TOKEN_TTL = Number(process.env.MOCK_TOKEN_TTL || 3600);

const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const KID = 'mock-key-1';
const codes = new Map();
const refreshTokens = new Map();

const b64url = (v) => Buffer.from(typeof v === 'string' ? v : JSON.stringify(v)).toString('base64url');

function signJwt(payload) {
  const header = { alg: 'RS256', typ: 'JWT', kid: KID };
  const input = `${b64url(header)}.${b64url(payload)}`;
  return `${input}.${crypto.sign('sha256', Buffer.from(input), privateKey).toString('base64url')}`;
}

function verifyJwt(token) {
  const parts = String(token).split('.');
  if (parts.length !== 3) return null;
  const ok = crypto.verify('sha256', Buffer.from(`${parts[0]}.${parts[1]}`), publicKey, Buffer.from(parts[2], 'base64url'));
  if (!ok) return null;
  const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString());
  return payload.exp > Date.now() / 1000 ? payload : null;
}

function issueTokens({ sub, scope, grant }) {
  const now = Math.floor(Date.now() / 1000);
  const base = { iss: ISSUER, aud: CLIENT_ID, iat: now, nbf: now, exp: now + TOKEN_TTL };
  const out = {
    access_token: signJwt({ ...base, sub, scope, azp: CLIENT_ID, client_id: CLIENT_ID, jti: crypto.randomUUID() }),
    token_type: 'Bearer',
    expires_in: TOKEN_TTL,
    scope,
  };
  if (grant !== 'client_credentials') {
    out.refresh_token = crypto.randomBytes(24).toString('base64url');
    refreshTokens.set(out.refresh_token, { sub, scope });
  }
  if (scope.split(' ').includes('openid')) {
    out.id_token = signJwt({ ...base, sub, email: `${sub}@example.com`, groups: ['poc-testers'] });
  }
  return out;
}

function send(res, status, body, headers = {}) {
  res.writeHead(status, { 'Content-Type': 'application/json', ...headers });
  res.end(typeof body === 'string' ? body : JSON.stringify(body, null, 2));
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (c) => (data += c));
    req.on('end', () => resolve(data));
  });
}

function clientFromRequest(req, form) {
  const auth = req.headers.authorization || '';
  if (auth.startsWith('Basic ')) {
    const [id, secret] = Buffer.from(auth.slice(6), 'base64').toString().split(':');
    return { id, secret, method: 'basic' };
  }
  return { id: form.get('client_id'), secret: form.get('client_secret'), method: form.get('client_secret') ? 'body' : 'none' };
}

async function handleToken(req, res) {
  const form = new URLSearchParams(await readBody(req));
  const client = clientFromRequest(req, form);
  const grant = form.get('grant_type');

  if (client.id !== CLIENT_ID) return send(res, 401, { error: 'invalid_client' });
  // Public clients (no secret) are only allowed with PKCE on the auth code grant.
  if (client.method !== 'none' && client.secret !== CLIENT_SECRET) return send(res, 401, { error: 'invalid_client' });

  if (grant === 'client_credentials') {
    if (client.method === 'none') return send(res, 401, { error: 'invalid_client' });
    return send(res, 200, issueTokens({ sub: CLIENT_ID, scope: form.get('scope') || 'default', grant }));
  }

  if (grant === 'authorization_code') {
    const entry = codes.get(form.get('code'));
    codes.delete(form.get('code')); // single use
    if (!entry || entry.expires < Date.now()) return send(res, 400, { error: 'invalid_grant', error_description: 'unknown, used or expired code' });
    if (entry.redirectUri !== form.get('redirect_uri')) return send(res, 400, { error: 'invalid_grant', error_description: 'redirect_uri mismatch' });
    if (entry.challenge) {
      const verifier = form.get('code_verifier') || '';
      const computed = crypto.createHash('sha256').update(verifier).digest('base64url');
      if (computed !== entry.challenge) return send(res, 400, { error: 'invalid_grant', error_description: 'PKCE verification failed' });
    } else if (client.method === 'none') {
      return send(res, 401, { error: 'invalid_client', error_description: 'public clients must use PKCE' });
    }
    return send(res, 200, issueTokens({ sub: entry.sub, scope: entry.scope, grant }));
  }

  if (grant === 'refresh_token') {
    const entry = refreshTokens.get(form.get('refresh_token'));
    if (!entry) return send(res, 400, { error: 'invalid_grant' });
    return send(res, 200, issueTokens({ ...entry, grant }));
  }

  return send(res, 400, { error: 'unsupported_grant_type' });
}

function handleAuthorize(url, res) {
  const p = url.searchParams;
  if (p.get('client_id') !== CLIENT_ID) return send(res, 400, { error: 'invalid_client' });
  if (p.get('response_type') !== 'code') return send(res, 400, { error: 'unsupported_response_type' });
  const redirectUri = p.get('redirect_uri');
  if (!redirectUri) return send(res, 400, { error: 'invalid_request', error_description: 'redirect_uri required' });

  const code = crypto.randomBytes(16).toString('base64url');
  codes.set(code, {
    redirectUri,
    sub: 'poc.user',
    scope: p.get('scope') || 'default',
    challenge: p.get('code_challenge_method') === 'S256' ? p.get('code_challenge') : null,
    expires: Date.now() + 60_000,
  });
  const target = new URL(redirectUri);
  target.searchParams.set('code', code);
  if (p.get('state')) target.searchParams.set('state', p.get('state'));
  console.log(`[authorize] issued code for ${redirectUri}`);
  res.writeHead(302, { Location: target.toString() });
  res.end();
}

async function handleApi(req, url, res) {
  const auth = req.headers.authorization || '';
  const claims = auth.startsWith('Bearer ') ? verifyJwt(auth.slice(7)) : null;
  const correlationId = req.headers['x-correlation-id'] || '-';
  // Mimics the log line a Devant integration would emit.
  console.log(
    `[api] ${new Date().toISOString()} ${req.method} ${url.pathname} correlationId=${correlationId} ` +
      `xff=${req.headers['x-forwarded-for'] || '-'} sub=${claims?.sub || '-'} status=${claims ? 200 : 401}`,
  );
  if (!claims) return send(res, 401, { error: 'invalid_token' }, { 'WWW-Authenticate': 'Bearer error="invalid_token"' });
  const body = await readBody(req);
  send(res, 200, {
    message: 'Hello from the mock API',
    method: req.method,
    path: url.pathname,
    correlationId,
    xForwardedFor: req.headers['x-forwarded-for'] || null,
    tokenSubject: claims.sub,
    tokenScope: claims.scope,
    requestBody: body || null,
  });
}

http
  .createServer(async (req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
    try {
      if (req.method === 'GET' && url.pathname === '/oauth2/authorize') return handleAuthorize(url, res);
      if (req.method === 'POST' && url.pathname === '/oauth2/token') return await handleToken(req, res);
      if (req.method === 'GET' && url.pathname === '/oauth2/jwks') {
        return send(res, 200, { keys: [{ ...publicKey.export({ format: 'jwk' }), kid: KID, use: 'sig', alg: 'RS256' }] });
      }
      if (url.pathname.startsWith('/api/')) return await handleApi(req, url, res);
      send(res, 404, { error: 'not_found' });
    } catch (err) {
      console.error(err);
      send(res, 500, { error: 'server_error' });
    }
  })
  .listen(PORT, () => {
    console.log(`Mock OAuth server on http://localhost:${PORT}  (client_id=${CLIENT_ID}, client_secret=${CLIENT_SECRET})`);
  });
