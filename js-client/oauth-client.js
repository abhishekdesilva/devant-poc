#!/usr/bin/env node
'use strict';

// ---------------------------------------------------------------------------
// POC 4: OAuth2 test client for Bijira-managed APIs.
//
// Covers both customer scenarios with one configurable client:
//   1. client-credentials — fetch a token, invoke the Bijira API, print a
//      correlation ID to look up in the Devant logs.
//   2. auth-code          — authorization code grant (optionally with PKCE):
//      open /authorize, capture the code on a localhost callback, exchange it
//      at the token endpoint, extract + decode (and optionally verify) the
//      JWT(s) in the response, then invoke the API (e.g. one hosted in the
//      Private Data Plane).
//
// Node 18+ only, no npm dependencies. Configuration precedence (lowest to
// highest): built-in defaults -> .env file -> environment variables ->
// --KEY=value command-line flags.
//
//   node oauth-client.js client-credentials
//   node oauth-client.js auth-code
//   node oauth-client.js decode <jwt>
// ---------------------------------------------------------------------------

const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const readline = require('readline');
const { spawn } = require('child_process');

const DEFAULTS = {
  // OAuth2 endpoints and client
  TOKEN_URL: '',
  AUTHORIZE_URL: '',
  CLIENT_ID: '',
  CLIENT_SECRET: '',
  TOKEN_AUTH_METHOD: 'basic', // basic | body | none (public client, PKCE)
  SCOPE: '',

  // Authorization code grant
  REDIRECT_URI: 'http://localhost:8080/callback',
  USE_PKCE: 'true',
  EXTRA_AUTHORIZE_PARAMS: '', // e.g. prompt=login&fidp=AzureAD
  OPEN_BROWSER: 'true',
  CALLBACK_TIMEOUT_SECONDS: '300',

  // JWT verification (optional — decode-only when JWKS_URL is empty)
  JWKS_URL: '',
  EXPECTED_ISSUER: '',
  EXPECTED_AUDIENCE: '',

  // API invocation (skipped when API_URL is empty)
  API_URL: '',
  API_METHOD: 'GET',
  API_BODY: '',
  API_CONTENT_TYPE: 'application/json',
  API_EXTRA_HEADERS: '', // JSON object, e.g. {"x-api-version":"v1"}
  CORRELATION_HEADER: 'X-Correlation-ID',
  FORWARDED_FOR: '', // optional X-Forwarded-For value for XFF tests

  // Output
  TOKEN_OUTPUT_FILE: '', // e.g. tokens.json — reusable from JMeter
  ENV_FILE: '.env',
};

const SECRET_KEYS = new Set(['CLIENT_SECRET']);

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const flags = {};
  const positional = [];
  for (const arg of argv) {
    const m = /^--([A-Za-z0-9_-]+)(?:=(.*))?$/.exec(arg);
    if (m) {
      flags[m[1].toUpperCase().replace(/-/g, '_')] = m[2] === undefined ? 'true' : m[2];
    } else {
      positional.push(arg);
    }
  }
  return { flags, positional };
}

function parseEnvFile(file) {
  const values = {};
  if (!fs.existsSync(file)) return values;
  for (const raw of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    values[key] = value;
  }
  return values;
}

// extraDefaults lets other scripts (load-test.js) add their own settings.
function loadConfig(flags, extraDefaults = {}) {
  const envFileName = flags.ENV_FILE || process.env.ENV_FILE || DEFAULTS.ENV_FILE;
  const envFile = path.isAbsolute(envFileName) ? envFileName : path.resolve(process.cwd(), envFileName);
  const fromFile = parseEnvFile(envFile);

  const defaults = { ...DEFAULTS, ...extraDefaults };
  const cfg = {};
  for (const key of Object.keys(defaults)) {
    cfg[key] = flags[key] ?? process.env[key] ?? fromFile[key] ?? defaults[key];
  }
  cfg._envFile = fs.existsSync(envFile) ? envFile : '(none)';
  return cfg;
}

const isTrue = (v) => /^(true|yes|1)$/i.test(String(v));

function requireKeys(cfg, keys) {
  const missing = keys.filter((k) => !cfg[k]);
  if (missing.length) {
    throw new Error(`Missing required config: ${missing.join(', ')} (set in .env, environment, or --KEY=value)`);
  }
}

function printConfig(cfg) {
  section('Configuration');
  console.log(`  env file: ${cfg._envFile}`);
  for (const key of Object.keys(DEFAULTS)) {
    if (key === 'ENV_FILE' || !cfg[key]) continue;
    const value = SECRET_KEYS.has(key) ? mask(cfg[key]) : cfg[key];
    console.log(`  ${key.padEnd(26)} ${value}`);
  }
}

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

function section(title) {
  console.log(`\n=== ${title} ${'='.repeat(Math.max(0, 70 - title.length))}`);
}

function mask(value) {
  if (!value) return '';
  return value.length <= 8 ? '****' : `${value.slice(0, 4)}…${value.slice(-4)}`;
}

function truncate(text, max = 2000) {
  return text.length > max ? `${text.slice(0, max)}… (${text.length - max} more chars)` : text;
}

function prettyBody(text) {
  try {
    return JSON.stringify(JSON.parse(text), null, 2);
  } catch {
    return text;
  }
}

// ---------------------------------------------------------------------------
// OAuth2
// ---------------------------------------------------------------------------

async function requestToken(cfg, params) {
  requireKeys(cfg, ['TOKEN_URL', 'CLIENT_ID']);
  const body = new URLSearchParams(params);
  const headers = {
    'Content-Type': 'application/x-www-form-urlencoded',
    Accept: 'application/json',
  };

  const method = cfg.TOKEN_AUTH_METHOD.toLowerCase();
  if (method === 'basic') {
    requireKeys(cfg, ['CLIENT_SECRET']);
    headers.Authorization = `Basic ${Buffer.from(`${cfg.CLIENT_ID}:${cfg.CLIENT_SECRET}`).toString('base64')}`;
  } else if (method === 'body') {
    requireKeys(cfg, ['CLIENT_SECRET']);
    body.set('client_id', cfg.CLIENT_ID);
    body.set('client_secret', cfg.CLIENT_SECRET);
  } else if (method === 'none') {
    body.set('client_id', cfg.CLIENT_ID);
  } else {
    throw new Error(`Unknown TOKEN_AUTH_METHOD "${cfg.TOKEN_AUTH_METHOD}" (use basic | body | none)`);
  }

  section(`Token request (grant_type=${params.grant_type})`);
  console.log(`  POST ${cfg.TOKEN_URL}`);
  console.log(`  client auth: ${method}`);

  const started = Date.now();
  const res = await fetch(cfg.TOKEN_URL, { method: 'POST', headers, body });
  const text = await res.text();
  console.log(`  -> HTTP ${res.status} in ${Date.now() - started} ms`);

  let json;
  try {
    json = JSON.parse(text);
  } catch {
    throw new Error(`Token endpoint returned non-JSON response:\n${truncate(text)}`);
  }
  if (!res.ok || !json.access_token) {
    throw new Error(`Token request failed (HTTP ${res.status}):\n${JSON.stringify(json, null, 2)}`);
  }

  console.log(`  token_type: ${json.token_type}  expires_in: ${json.expires_in}  scope: ${json.scope ?? '(none)'}`);
  console.log(`  returned: ${Object.keys(json).join(', ')}`);
  return json;
}

async function clientCredentialsFlow(cfg) {
  const params = { grant_type: 'client_credentials' };
  if (cfg.SCOPE) params.scope = cfg.SCOPE;
  return requestToken(cfg, params);
}

function base64url(buf) {
  return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function authorizationCodeFlow(cfg) {
  requireKeys(cfg, ['AUTHORIZE_URL', 'TOKEN_URL', 'CLIENT_ID', 'REDIRECT_URI']);

  const state = base64url(crypto.randomBytes(16));
  const authUrl = new URL(cfg.AUTHORIZE_URL);
  authUrl.searchParams.set('response_type', 'code');
  authUrl.searchParams.set('client_id', cfg.CLIENT_ID);
  authUrl.searchParams.set('redirect_uri', cfg.REDIRECT_URI);
  authUrl.searchParams.set('state', state);
  if (cfg.SCOPE) authUrl.searchParams.set('scope', cfg.SCOPE);

  let codeVerifier;
  if (isTrue(cfg.USE_PKCE)) {
    codeVerifier = base64url(crypto.randomBytes(32));
    authUrl.searchParams.set('code_challenge', base64url(crypto.createHash('sha256').update(codeVerifier).digest()));
    authUrl.searchParams.set('code_challenge_method', 'S256');
  }
  for (const [k, v] of new URLSearchParams(cfg.EXTRA_AUTHORIZE_PARAMS)) {
    authUrl.searchParams.set(k, v);
  }

  section('Authorization request');
  console.log(`  PKCE: ${codeVerifier ? 'S256' : 'disabled'}`);
  console.log(`  Open this URL and sign in:\n\n  ${authUrl.toString()}\n`);

  const redirect = new URL(cfg.REDIRECT_URI);
  const isLocal = redirect.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(redirect.hostname);

  const callbackParams = isLocal
    ? await waitForCallback(cfg, redirect, authUrl.toString())
    : await promptForRedirect(redirect);

  if (callbackParams.get('error')) {
    throw new Error(`Authorization failed: ${callbackParams.get('error')} — ${callbackParams.get('error_description') ?? ''}`);
  }
  if (callbackParams.get('state') !== state) {
    throw new Error('State mismatch on callback — possible CSRF or stale browser tab. Retry the flow.');
  }
  const code = callbackParams.get('code');
  if (!code) throw new Error('Callback did not include an authorization code.');
  console.log(`  received authorization code: ${mask(code)}`);

  const params = { grant_type: 'authorization_code', code, redirect_uri: cfg.REDIRECT_URI };
  if (codeVerifier) params.code_verifier = codeVerifier;
  return requestToken(cfg, params);
}

// Listens on the local redirect URI and resolves with the callback query params.
function waitForCallback(cfg, redirect, authUrl) {
  return new Promise((resolve, reject) => {
    const port = Number(redirect.port || 80);
    const server = http.createServer((req, res) => {
      const url = new URL(req.url, `http://${req.headers.host}`);
      if (url.pathname !== redirect.pathname) {
        res.writeHead(404).end();
        return;
      }
      const ok = url.searchParams.has('code');
      res.writeHead(ok ? 200 : 400, { 'Content-Type': 'text/html' });
      res.end(`<html><body style="font-family:sans-serif"><h3>${
        ok ? 'Authorization code received.' : 'Authorization failed.'
      }</h3><p>You can close this tab and return to the terminal.</p></body></html>`);
      clearTimeout(timer);
      server.close();
      resolve(url.searchParams);
    });

    const timer = setTimeout(() => {
      server.close();
      reject(new Error(`Timed out after ${cfg.CALLBACK_TIMEOUT_SECONDS}s waiting for the redirect to ${redirect}`));
    }, Number(cfg.CALLBACK_TIMEOUT_SECONDS) * 1000);

    server.on('error', (err) => {
      clearTimeout(timer);
      reject(new Error(`Could not listen on ${redirect.host} for the callback: ${err.message}`));
    });
    server.listen(port, redirect.hostname.replace(/^\[|\]$/g, ''), () => {
      console.log(`  waiting for callback on ${redirect.origin}${redirect.pathname} …`);
      if (isTrue(cfg.OPEN_BROWSER)) openBrowser(authUrl);
    });
  });
}

// For non-local redirect URIs: the user pastes the URL the browser landed on.
async function promptForRedirect(redirect) {
  console.log(`  REDIRECT_URI (${redirect.origin}) is not a local http address, so this client cannot`);
  console.log('  capture the callback. After signing in, copy the full URL from the browser address bar.');
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const answer = await new Promise((resolve) => rl.question('\n  Paste redirected URL: ', resolve));
  rl.close();
  return new URL(answer.trim()).searchParams;
}

function openBrowser(url) {
  const [cmd, args] =
    process.platform === 'darwin'
      ? ['open', [url]]
      : process.platform === 'win32'
        ? ['cmd', ['/c', 'start', '""', url.replace(/&/g, '^&')]]
        : ['xdg-open', [url]];
  spawn(cmd, args, { stdio: 'ignore', detached: true }).on('error', () => {}).unref();
}

// ---------------------------------------------------------------------------
// JWT
// ---------------------------------------------------------------------------

function decodeJwt(token) {
  const parts = String(token).split('.');
  if (parts.length !== 3) return null;
  try {
    const decode = (p) => JSON.parse(Buffer.from(p, 'base64url').toString('utf8'));
    return { header: decode(parts[0]), payload: decode(parts[1]), parts };
  } catch {
    return null;
  }
}

function formatEpoch(seconds) {
  if (typeof seconds !== 'number') return '';
  const delta = Math.round(seconds - Date.now() / 1000);
  return `${new Date(seconds * 1000).toISOString()} (${delta >= 0 ? `in ${delta}s` : `${-delta}s ago`})`;
}

const VERIFY_PARAMS = {
  RS256: ['sha256', {}],
  RS384: ['sha384', {}],
  RS512: ['sha512', {}],
  PS256: ['sha256', { padding: crypto.constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }],
  PS384: ['sha384', { padding: crypto.constants.RSA_PKCS1_PSS_PADDING, saltLength: 48 }],
  PS512: ['sha512', { padding: crypto.constants.RSA_PKCS1_PSS_PADDING, saltLength: 64 }],
  ES256: ['sha256', { dsaEncoding: 'ieee-p1363' }],
  ES384: ['sha384', { dsaEncoding: 'ieee-p1363' }],
  ES512: ['sha512', { dsaEncoding: 'ieee-p1363' }],
};

let jwksCache;

async function verifyJwt(cfg, jwt) {
  const results = [];
  const { header, payload, parts } = jwt;

  const params = VERIFY_PARAMS[header.alg];
  if (!params) {
    results.push(['signature', false, `unsupported alg "${header.alg}"`]);
  } else {
    if (!jwksCache) {
      const res = await fetch(cfg.JWKS_URL, { headers: { Accept: 'application/json' } });
      if (!res.ok) throw new Error(`JWKS fetch failed: HTTP ${res.status} from ${cfg.JWKS_URL}`);
      jwksCache = (await res.json()).keys ?? [];
    }
    const jwk = jwksCache.find((k) => k.kid === header.kid) ?? (jwksCache.length === 1 ? jwksCache[0] : undefined);
    if (!jwk) {
      results.push(['signature', false, `no JWKS key matches kid "${header.kid}"`]);
    } else {
      const [hash, options] = params;
      const key = crypto.createPublicKey({ key: jwk, format: 'jwk' });
      const valid = crypto.verify(
        hash,
        Buffer.from(`${parts[0]}.${parts[1]}`),
        { key, ...options },
        Buffer.from(parts[2], 'base64url'),
      );
      results.push(['signature', valid, `${header.alg}, kid=${jwk.kid ?? '(none)'}`]);
    }
  }

  const now = Date.now() / 1000;
  if (payload.exp !== undefined) results.push(['exp', payload.exp > now, formatEpoch(payload.exp)]);
  if (payload.nbf !== undefined) results.push(['nbf', payload.nbf <= now + 30, formatEpoch(payload.nbf)]);
  if (cfg.EXPECTED_ISSUER) results.push(['iss', payload.iss === cfg.EXPECTED_ISSUER, String(payload.iss)]);
  if (cfg.EXPECTED_AUDIENCE) {
    const aud = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    results.push(['aud', aud.includes(cfg.EXPECTED_AUDIENCE), aud.join(', ')]);
  }
  return results;
}

async function inspectToken(cfg, label, token) {
  section(`JWT extraction: ${label}`);
  const jwt = decodeJwt(token);
  if (!jwt) {
    console.log(`  ${label} is not a JWT (opaque token): ${mask(token)}`);
    return;
  }
  console.log('  header:');
  console.log(indent(JSON.stringify(jwt.header, null, 2), 4));
  console.log('  payload:');
  console.log(indent(JSON.stringify(jwt.payload, null, 2), 4));
  for (const claim of ['iat', 'nbf', 'exp']) {
    if (jwt.payload[claim] !== undefined) console.log(`  ${claim}: ${formatEpoch(jwt.payload[claim])}`);
  }

  if (!cfg.JWKS_URL) {
    console.log('  verification: skipped (set JWKS_URL to verify signature and claims)');
    return;
  }
  const results = await verifyJwt(cfg, jwt);
  console.log('  verification:');
  for (const [check, ok, detail] of results) {
    console.log(`    ${ok ? 'PASS' : 'FAIL'}  ${check.padEnd(10)} ${detail}`);
  }
}

function indent(text, n) {
  const pad = ' '.repeat(n);
  return text
    .split('\n')
    .map((l) => pad + l)
    .join('\n');
}

// ---------------------------------------------------------------------------
// API invocation
// ---------------------------------------------------------------------------

async function callApi(cfg, accessToken) {
  const correlationId = crypto.randomUUID();
  const headers = {
    Authorization: `Bearer ${accessToken}`,
    Accept: 'application/json',
    [cfg.CORRELATION_HEADER]: correlationId,
  };
  if (cfg.FORWARDED_FOR) headers['X-Forwarded-For'] = cfg.FORWARDED_FOR;
  if (cfg.API_EXTRA_HEADERS) {
    try {
      Object.assign(headers, JSON.parse(cfg.API_EXTRA_HEADERS));
    } catch {
      throw new Error('API_EXTRA_HEADERS must be a JSON object, e.g. {"x-api-version":"v1"}');
    }
  }

  const method = cfg.API_METHOD.toUpperCase();
  const init = { method, headers };
  if (cfg.API_BODY && !['GET', 'HEAD'].includes(method)) {
    headers['Content-Type'] = cfg.API_CONTENT_TYPE;
    init.body = cfg.API_BODY;
  }

  section('API invocation');
  console.log(`  ${method} ${cfg.API_URL}`);
  for (const [k, v] of Object.entries(headers)) {
    console.log(`  > ${k}: ${k === 'Authorization' ? `Bearer ${mask(accessToken)}` : v}`);
  }

  const sentAt = new Date();
  const started = Date.now();
  const res = await fetch(cfg.API_URL, init);
  const text = await res.text();

  console.log(`  -> HTTP ${res.status} ${res.statusText} in ${Date.now() - started} ms`);
  for (const [k, v] of res.headers) console.log(`  < ${k}: ${v}`);
  console.log('  body:');
  console.log(indent(truncate(prettyBody(text)), 4));

  section('Verify in Devant');
  console.log('  Open the Devant console -> your integration -> Observability -> Logs, and search for:');
  console.log(`    ${cfg.CORRELATION_HEADER}: ${correlationId}`);
  console.log(`    sent at: ${sentAt.toISOString()} (local: ${sentAt.toString()})`);
  console.log('  (the backend must log incoming headers for the correlation ID to appear)');

  return res.ok;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function usage() {
  console.log(`Usage:
  node oauth-client.js client-credentials   fetch token (client credentials), call API_URL
  node oauth-client.js auth-code            authorization code (+PKCE) flow, extract JWT, call API_URL
  node oauth-client.js decode <jwt>         decode (and verify, if JWKS_URL is set) a JWT

Config comes from .env (see .env.example), environment variables, or --KEY=value flags.
Example: node oauth-client.js auth-code --SCOPE="openid email" --API_URL=https://.../orders`);
}

async function main() {
  const { flags, positional } = parseArgs(process.argv.slice(2));
  const [command, arg] = positional;
  if (!command || flags.HELP) {
    usage();
    process.exit(command ? 0 : 1);
  }

  const cfg = loadConfig(flags);

  if (command === 'decode') {
    if (!arg) throw new Error('Usage: node oauth-client.js decode <jwt>');
    await inspectToken(cfg, 'token', arg);
    return;
  }

  let tokens;
  if (command === 'client-credentials') {
    printConfig(cfg);
    tokens = await clientCredentialsFlow(cfg);
  } else if (command === 'auth-code') {
    printConfig(cfg);
    tokens = await authorizationCodeFlow(cfg);
  } else {
    usage();
    process.exit(1);
  }

  await inspectToken(cfg, 'access_token', tokens.access_token);
  if (tokens.id_token) await inspectToken(cfg, 'id_token', tokens.id_token);

  if (cfg.TOKEN_OUTPUT_FILE) {
    fs.writeFileSync(cfg.TOKEN_OUTPUT_FILE, JSON.stringify({ ...tokens, obtained_at: new Date().toISOString() }, null, 2), {
      mode: 0o600,
    });
    console.log(`\n  token response saved to ${path.resolve(cfg.TOKEN_OUTPUT_FILE)}`);
  }

  if (!cfg.API_URL) {
    console.log('\n  API_URL not set — skipping API invocation.');
    return;
  }
  const ok = await callApi(cfg, tokens.access_token);
  if (!ok) process.exitCode = 2;
}

if (require.main === module) {
  main().catch((err) => {
    console.error(`\nERROR: ${err.message}`);
    if (err.cause) console.error(`  cause: ${err.cause.message ?? err.cause}`);
    process.exit(1);
  });
}

module.exports = {
  parseArgs,
  loadConfig,
  isTrue,
  requireKeys,
  mask,
  section,
  requestToken,
  clientCredentialsFlow,
  decodeJwt,
};
