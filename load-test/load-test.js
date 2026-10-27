#!/usr/bin/env node
'use strict';

// ---------------------------------------------------------------------------
// Load test for a Bijira-managed API (Node 18+, no npm dependencies).
//
// Obtains an OAuth2 access token (client credentials, refresh token, or a
// token you already have), then drives CONCURRENCY virtual users against
// API_URL for DURATION_SECONDS, optionally capped at TARGET_RPS. Tokens are
// renewed automatically before they expire. Prints live progress and a final
// report (throughput, latency percentiles, status codes, errors), and can write
// every request — with its correlation ID for Devant log lookup — to a CSV.
//
// Uses the same configuration sources as oauth-client.js (.env file,
// environment variables, --KEY=value flags).
//
//   node load-test.js
//   node load-test.js --CONCURRENCY=50 --DURATION_SECONDS=300 --TARGET_RPS=100
// ---------------------------------------------------------------------------

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { performance } = require('perf_hooks');
const { parseArgs, loadConfig, requireKeys, mask, section, requestToken, decodeJwt } = require('./oauth-client');

const LOAD_DEFAULTS = {
  // Token source
  LOAD_GRANT_TYPE: 'client_credentials', // client_credentials | refresh_token | static
  ACCESS_TOKEN: '', // static: the token to use
  REFRESH_TOKEN: '', // refresh_token: the refresh token to start from
  TOKEN_FILE: '', // token response saved by `oauth-client.js auth-code` (TOKEN_OUTPUT_FILE)
  TOKEN_REFRESH_MARGIN_SECONDS: '60',

  // Load profile
  CONCURRENCY: '10',
  DURATION_SECONDS: '60',
  RAMP_UP_SECONDS: '0',
  TARGET_RPS: '0', // 0 = no cap (as fast as CONCURRENCY allows)
  MAX_REQUESTS: '0', // 0 = no limit
  THINK_TIME_MS: '0',
  REQUEST_TIMEOUT_MS: '30000',

  // Pass/fail and output
  EXPECTED_STATUS: '200',
  MAX_ERROR_RATE_PERCENT: '1',
  PROGRESS_INTERVAL_SECONDS: '5',
  RESULTS_CSV: '',
  REPORT_JSON: '',
  START_DELAY_SECONDS: '5',
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function toNumber(cfg, key, { min = 0 } = {}) {
  const value = Number(cfg[key]);
  if (!Number.isFinite(value) || value < min) throw new Error(`${key} must be a number >= ${min} (got "${cfg[key]}")`);
  return value;
}

// ---------------------------------------------------------------------------
// Token management
// ---------------------------------------------------------------------------

class TokenManager {
  constructor(cfg) {
    this.cfg = cfg;
    this.grant = cfg.LOAD_GRANT_TYPE.toLowerCase();
    this.marginMs = toNumber(cfg, 'TOKEN_REFRESH_MARGIN_SECONDS') * 1000;
    this.accessToken = cfg.ACCESS_TOKEN;
    this.refreshToken = cfg.REFRESH_TOKEN;
    this.expiresAt = 0;
    this.renewals = 0;
    this.lastRenewal = 0;
    this.pending = null;
  }

  async init() {
    if (this.cfg.TOKEN_FILE) {
      const saved = JSON.parse(fs.readFileSync(this.cfg.TOKEN_FILE, 'utf8'));
      this.accessToken ||= saved.access_token ?? '';
      this.refreshToken ||= saved.refresh_token ?? '';
    }

    if (this.grant === 'static') {
      if (!this.accessToken) throw new Error('LOAD_GRANT_TYPE=static needs ACCESS_TOKEN or TOKEN_FILE');
      const exp = decodeJwt(this.accessToken)?.payload?.exp;
      this.expiresAt = typeof exp === 'number' ? exp * 1000 : 0;
    } else if (this.grant === 'client_credentials' || this.grant === 'refresh_token') {
      if (this.grant === 'refresh_token' && !this.refreshToken) {
        throw new Error('LOAD_GRANT_TYPE=refresh_token needs REFRESH_TOKEN or TOKEN_FILE');
      }
      await this.fetchToken();
    } else {
      throw new Error(`Unknown LOAD_GRANT_TYPE "${this.cfg.LOAD_GRANT_TYPE}" (use client_credentials | refresh_token | static)`);
    }
  }

  async fetchToken() {
    const params = this.grant === 'refresh_token'
      ? { grant_type: 'refresh_token', refresh_token: this.refreshToken }
      : { grant_type: 'client_credentials' };
    if (this.cfg.SCOPE) params.scope = this.cfg.SCOPE;

    const json = await requestToken(this.cfg, params);
    this.accessToken = json.access_token;
    if (json.refresh_token) this.refreshToken = json.refresh_token; // servers may rotate refresh tokens
    const exp = decodeJwt(json.access_token)?.payload?.exp;
    this.expiresAt = typeof exp === 'number' ? exp * 1000 : json.expires_in ? Date.now() + json.expires_in * 1000 : 0;
    this.lastRenewal = Date.now();
  }

  // Returns a valid token, renewing it (once, shared by all virtual users) when close to expiry.
  async get() {
    // Cap the margin at half the token lifetime so short-lived tokens aren't renewed on every request.
    const marginMs = Math.min(this.marginMs, (this.expiresAt - this.lastRenewal) / 2);
    if (this.grant !== 'static' && this.expiresAt && Date.now() >= this.expiresAt - marginMs) {
      await this.renew();
    }
    return this.accessToken;
  }

  renew() {
    if (this.grant === 'static') return Promise.resolve();
    if (!this.pending) {
      this.pending = this.fetchToken()
        .then(() => {
          this.renewals += 1;
        })
        .finally(() => {
          this.pending = null;
        });
    }
    return this.pending;
  }

  // After a 401: renew, but not more than once every 10 s, so a misconfigured
  // API doesn't turn into a token-endpoint load test.
  onUnauthorized() {
    if (this.grant !== 'static' && Date.now() - this.lastRenewal > 10_000) {
      this.renew().catch((err) => console.error(`  token renewal failed: ${err.message}`));
    }
  }
}

// ---------------------------------------------------------------------------
// Statistics
// ---------------------------------------------------------------------------

function percentile(sorted, p) {
  if (!sorted.length) return 0;
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1))];
}

function latencySummary(latencies) {
  const sorted = Float64Array.from(latencies).sort();
  const sum = latencies.reduce((a, b) => a + b, 0);
  const round = (v) => Math.round(v * 10) / 10;
  return {
    min: round(sorted[0] ?? 0),
    avg: round(sorted.length ? sum / sorted.length : 0),
    p50: round(percentile(sorted, 50)),
    p90: round(percentile(sorted, 90)),
    p95: round(percentile(sorted, 95)),
    p99: round(percentile(sorted, 99)),
    max: round(sorted[sorted.length - 1] ?? 0),
  };
}

class Stats {
  constructor() {
    this.total = 0;
    this.ok = 0;
    this.failed = 0;
    this.bytes = 0;
    this.latencies = [];
    this.statusCounts = {};
    this.errorCounts = {};
    this.window = [];
  }

  record({ status, ok, latencyMs, bytes, error }) {
    this.total += 1;
    if (ok) this.ok += 1;
    else this.failed += 1;
    this.bytes += bytes;
    if (status) {
      this.statusCounts[status] = (this.statusCounts[status] ?? 0) + 1;
      this.latencies.push(latencyMs);
      this.window.push(latencyMs);
    } else {
      this.errorCounts[error] = (this.errorCounts[error] ?? 0) + 1;
    }
  }

  takeWindow() {
    const w = this.window;
    this.window = [];
    return w;
  }
}

// ---------------------------------------------------------------------------
// Load generation
// ---------------------------------------------------------------------------

// Spaces request starts evenly so the overall rate stays at or below rps.
function createRateLimiter(rps) {
  if (!rps) return async () => {};
  const intervalMs = 1000 / rps;
  let next = performance.now();
  return async () => {
    const now = performance.now();
    next = Math.max(next, now);
    const wait = next - now;
    next += intervalMs;
    if (wait > 0) await sleep(wait);
  };
}

function buildStaticHeaders(cfg) {
  const headers = { Accept: 'application/json' };
  if (cfg.FORWARDED_FOR) headers['X-Forwarded-For'] = cfg.FORWARDED_FOR;
  if (cfg.API_EXTRA_HEADERS) {
    try {
      Object.assign(headers, JSON.parse(cfg.API_EXTRA_HEADERS));
    } catch {
      throw new Error('API_EXTRA_HEADERS must be a JSON object, e.g. {"x-api-version":"v1"}');
    }
  }
  const method = cfg.API_METHOD.toUpperCase();
  if (cfg.API_BODY && !['GET', 'HEAD'].includes(method)) headers['Content-Type'] = cfg.API_CONTENT_TYPE;
  return headers;
}

async function runLoad(cfg, tokens) {
  const concurrency = toNumber(cfg, 'CONCURRENCY', { min: 1 });
  const durationMs = toNumber(cfg, 'DURATION_SECONDS', { min: 1 }) * 1000;
  const rampUpMs = toNumber(cfg, 'RAMP_UP_SECONDS') * 1000;
  const maxRequests = toNumber(cfg, 'MAX_REQUESTS');
  const thinkMs = toNumber(cfg, 'THINK_TIME_MS');
  const timeoutMs = toNumber(cfg, 'REQUEST_TIMEOUT_MS', { min: 1 });
  const progressMs = toNumber(cfg, 'PROGRESS_INTERVAL_SECONDS', { min: 1 }) * 1000;
  const expectedStatus = Number(cfg.EXPECTED_STATUS);
  const method = cfg.API_METHOD.toUpperCase();
  const body = cfg.API_BODY && !['GET', 'HEAD'].includes(method) ? cfg.API_BODY : undefined;
  const staticHeaders = buildStaticHeaders(cfg);
  const limiter = createRateLimiter(toNumber(cfg, 'TARGET_RPS'));

  const csv = cfg.RESULTS_CSV ? fs.createWriteStream(cfg.RESULTS_CSV) : null;
  csv?.write('timestamp,elapsed_ms,user,status,ok,latency_ms,bytes,correlation_id,error\n');

  const stats = new Stats();
  const startedAt = Date.now();
  const startPerf = performance.now();
  const endAt = startedAt + durationMs;
  let issued = 0;
  let activeUsers = 0;
  let inFlight = 0;
  let stopRequested = false;

  const onSigint = () => {
    if (stopRequested) process.exit(130);
    stopRequested = true;
    console.log('\n  Stopping: finishing in-flight requests (Ctrl+C again to quit immediately)…');
  };
  process.on('SIGINT', onSigint);

  const shouldStop = () => stopRequested || Date.now() >= endAt || (maxRequests > 0 && issued >= maxRequests);

  async function sendOne(user) {
    const correlationId = crypto.randomUUID();
    const headers = {
      ...staticHeaders,
      Authorization: `Bearer ${await tokens.get()}`,
      [cfg.CORRELATION_HEADER]: correlationId,
    };

    let status = 0;
    let bytes = 0;
    let error = '';
    inFlight += 1;
    const t0 = performance.now();
    try {
      const res = await fetch(cfg.API_URL, { method, headers, body, signal: AbortSignal.timeout(timeoutMs) });
      bytes = (await res.arrayBuffer()).byteLength;
      status = res.status;
    } catch (err) {
      // fetch wraps network failures; the useful code (ECONNREFUSED, ENOTFOUND, …) is on the cause.
      error = err.name === 'TimeoutError'
        ? 'timeout'
        : err.cause?.code ?? err.cause?.errors?.[0]?.code ?? err.cause?.name ?? err.name ?? 'error';
    }
    const latencyMs = performance.now() - t0;
    inFlight -= 1;

    const ok = status === expectedStatus;
    stats.record({ status, ok, latencyMs, bytes, error });
    if (status === 401) tokens.onUnauthorized();
    csv?.write(
      `${new Date().toISOString()},${Math.round(performance.now() - startPerf)},${user},${status || ''},${ok},` +
        `${latencyMs.toFixed(1)},${bytes},${correlationId},${error}\n`,
    );
  }

  async function virtualUser(user) {
    if (rampUpMs) await sleep((rampUpMs * user) / concurrency);
    if (shouldStop()) return;
    activeUsers += 1;
    while (!shouldStop()) {
      await limiter();
      if (shouldStop()) break;
      issued += 1;
      await sendOne(user);
      if (thinkMs) await sleep(thinkMs);
    }
    activeUsers -= 1;
  }

  section('Running');
  let lastTotal = 0;
  let lastTick = performance.now();
  const ticker = setInterval(() => {
    const now = performance.now();
    const window = stats.takeWindow();
    const summary = latencySummary(window);
    const rps = ((stats.total - lastTotal) * 1000) / (now - lastTick);
    lastTotal = stats.total;
    lastTick = now;
    const elapsed = Math.round((now - startPerf) / 1000);
    console.log(
      `  [${String(elapsed).padStart(4)}s] users=${activeUsers}/${concurrency} in-flight=${inFlight} ` +
        `requests=${stats.total} rps=${rps.toFixed(1)} ok=${stats.ok} failed=${stats.failed} ` +
        `p50=${summary.p50}ms p95=${summary.p95}ms`,
    );
  }, progressMs);

  await Promise.all(Array.from({ length: concurrency }, (_, i) => virtualUser(i)));

  clearInterval(ticker);
  process.off('SIGINT', onSigint);
  if (csv) await new Promise((resolve) => csv.end(resolve));

  const elapsedSec = (performance.now() - startPerf) / 1000;
  return {
    startedAt: new Date(startedAt).toISOString(),
    finishedAt: new Date().toISOString(),
    durationSeconds: Math.round(elapsedSec * 10) / 10,
    stoppedEarly: stopRequested,
    requests: stats.total,
    succeeded: stats.ok,
    failed: stats.failed,
    errorRatePercent: stats.total ? Math.round((stats.failed / stats.total) * 10000) / 100 : 0,
    throughputRps: Math.round((stats.total / elapsedSec) * 10) / 10,
    latencyMs: latencySummary(stats.latencies),
    statusCodes: stats.statusCounts,
    networkErrors: stats.errorCounts,
    bytesReceived: stats.bytes,
    tokenRenewals: tokens.renewals,
  };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function printPlan(cfg, tokens) {
  section('Load test plan');
  const rows = [
    ['Target', `${cfg.API_METHOD.toUpperCase()} ${cfg.API_URL}`],
    ['Token', `${cfg.LOAD_GRANT_TYPE}${tokens.expiresAt ? ` (expires ${new Date(tokens.expiresAt).toISOString()})` : ''}`],
    ['Virtual users', cfg.CONCURRENCY],
    ['Duration', `${cfg.DURATION_SECONDS}s (ramp-up ${cfg.RAMP_UP_SECONDS}s)`],
    ['Rate cap', Number(cfg.TARGET_RPS) ? `${cfg.TARGET_RPS} req/s` : 'none'],
    ['Max requests', Number(cfg.MAX_REQUESTS) ? cfg.MAX_REQUESTS : 'no limit'],
    ['Think time', `${cfg.THINK_TIME_MS} ms`],
    ['Expected status', cfg.EXPECTED_STATUS],
    ['Pass threshold', `error rate <= ${cfg.MAX_ERROR_RATE_PERCENT}%`],
    ['Results CSV', cfg.RESULTS_CSV || '(off)'],
  ];
  for (const [k, v] of rows) console.log(`  ${k.padEnd(16)} ${v}`);

  if (cfg.LOAD_GRANT_TYPE === 'static' && tokens.expiresAt) {
    const runEndsAt = Date.now() + (Number(cfg.START_DELAY_SECONDS) + Number(cfg.DURATION_SECONDS)) * 1000;
    if (tokens.expiresAt < runEndsAt) {
      console.log('\n  WARNING: the static token expires before the run ends — expect 401s. Use client_credentials or refresh_token.');
    }
  }
}

function printReport(report) {
  section('Results');
  const l = report.latencyMs;
  console.log(`  Duration         ${report.durationSeconds}s${report.stoppedEarly ? ' (stopped early)' : ''}`);
  console.log(`  Requests         ${report.requests}  (succeeded ${report.succeeded}, failed ${report.failed})`);
  console.log(`  Error rate       ${report.errorRatePercent}%`);
  console.log(`  Throughput       ${report.throughputRps} req/s`);
  console.log(`  Latency (ms)     min ${l.min} | avg ${l.avg} | p50 ${l.p50} | p90 ${l.p90} | p95 ${l.p95} | p99 ${l.p99} | max ${l.max}`);
  console.log(`  Status codes     ${JSON.stringify(report.statusCodes)}`);
  if (Object.keys(report.networkErrors).length) console.log(`  Network errors   ${JSON.stringify(report.networkErrors)}`);
  console.log(`  Token renewals   ${report.tokenRenewals}`);
}

async function main() {
  const { flags } = parseArgs(process.argv.slice(2));
  if (flags.HELP) {
    console.log('Usage: node load-test.js [--KEY=value ...]   (see README.md for all settings)');
    return;
  }
  const cfg = loadConfig(flags, LOAD_DEFAULTS);
  requireKeys(cfg, ['API_URL']);

  section('Token');
  console.log(`  env file: ${cfg._envFile}`);
  const tokens = new TokenManager(cfg);
  await tokens.init();
  console.log(`  access token: ${mask(tokens.accessToken)}`);

  printPlan(cfg, tokens);
  const delay = toNumber(cfg, 'START_DELAY_SECONDS');
  if (delay > 0) {
    console.log(`\n  Starting in ${delay}s — press Ctrl+C to abort.`);
    await sleep(delay * 1000);
  }

  const report = await runLoad(cfg, tokens);
  printReport(report);

  if (cfg.REPORT_JSON) {
    fs.writeFileSync(cfg.REPORT_JSON, JSON.stringify({ config: publicConfig(cfg), ...report }, null, 2));
    console.log(`\n  report saved to ${path.resolve(cfg.REPORT_JSON)}`);
  }
  if (cfg.RESULTS_CSV) console.log(`  per-request results saved to ${path.resolve(cfg.RESULTS_CSV)}`);

  const passed = report.requests > 0 && report.errorRatePercent <= Number(cfg.MAX_ERROR_RATE_PERCENT);
  console.log(`\n  ${passed ? 'PASS' : 'FAIL'}: error rate ${report.errorRatePercent}% (threshold ${cfg.MAX_ERROR_RATE_PERCENT}%)`);
  if (!passed) process.exitCode = 3;
}

// The settings that shaped the run, without secrets, for the JSON report.
function publicConfig(cfg) {
  const keys = ['API_URL', 'API_METHOD', 'TOKEN_URL', 'LOAD_GRANT_TYPE', ...Object.keys(LOAD_DEFAULTS)];
  const hidden = new Set(['ACCESS_TOKEN', 'REFRESH_TOKEN']);
  return Object.fromEntries(keys.filter((k) => !hidden.has(k)).map((k) => [k, cfg[k]]));
}

main().catch((err) => {
  console.error(`\nERROR: ${err.message}`);
  if (err.cause) console.error(`  cause: ${err.cause.message ?? err.cause}`);
  process.exit(1);
});
