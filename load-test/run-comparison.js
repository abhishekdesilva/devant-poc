#!/usr/bin/env node
// Runs the same load scenarios against the isolated and non-isolated variants of
// the isolation demo, one after the other, and writes a side-by-side summary.
//
// Each scenario is a work type and a number of concurrent users, for example
// "cpu:10" (10 users calling GET /cpu) or "io:25" (25 users calling GET /io).
// For every scenario both variants get the same load, in alternating order so
// neither always goes first. Each run is an ordinary load-test.js run; its JSON
// report and per-request CSV are kept in the results folder.
//
// Usage: node run-comparison.js [--KEY=value ...]   (settings: see .env.example)

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { parseArgs, loadConfig, requireKeys, requestToken, mask } = require('./oauth-client');
const { summarize } = require('./summarize');

const RUN_DEFAULTS = {
  ISOLATED_URL: '', // invoke URL of the isolated variant, ending in /v1.0 (or http://localhost:9091 locally)
  NON_ISOLATED_URL: '', // invoke URL of the non-isolated variant
  SCENARIOS: 'cpu:1,cpu:10,cpu:25,io:25',
  DURATION_SECONDS: '60', // per run
  WARMUP_SECONDS: '20', // per variant, before the first scenario; not included in the results
  COOLDOWN_SECONDS: '10', // pause between runs
  CPU_ITERATIONS: '10000000', // GET /cpu?iterations=
  IO_MS: '200', // GET /io?ms=
  REQUEST_TIMEOUT_MS: '30000',
  OUTPUT_DIR: 'results',
  RUN_LABEL: '', // optional name for the results folder, e.g. devant or local-14-cores
  LOAD_GRANT_TYPE: 'client_credentials', // client_credentials | static
  ACCESS_TOKEN: '', // static: the token to use
};

const VARIANTS = [
  { name: 'non-isolated', urlKey: 'NON_ISOLATED_URL' },
  { name: 'isolated', urlKey: 'ISOLATED_URL' },
];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function parseScenarios(text) {
  return text.split(',').map((s) => s.trim()).filter(Boolean).map((s) => {
    const m = /^(cpu|io):(\d+)$/.exec(s);
    if (!m || Number(m[2]) < 1) throw new Error(`Invalid scenario "${s}" (use cpu:<users> or io:<users>)`);
    return { work: m[1], users: Number(m[2]), id: `${m[1]}-${m[2]}users` };
  });
}

function workUrl(base, work, cfg) {
  const root = base.replace(/\/+$/, '');
  return work === 'cpu' ? `${root}/cpu?iterations=${cfg.CPU_ITERATIONS}` : `${root}/io?ms=${cfg.IO_MS}`;
}

// A token for the runner's own /stats calls. load-test.js gets its own.
async function getToken(cfg) {
  if (cfg.LOAD_GRANT_TYPE === 'static') {
    if (!cfg.ACCESS_TOKEN) throw new Error('LOAD_GRANT_TYPE=static needs ACCESS_TOKEN');
    return cfg.ACCESS_TOKEN;
  }
  return (await requestToken(cfg, { grant_type: 'client_credentials' })).access_token;
}

async function getStats(base, token) {
  const res = await fetch(`${base.replace(/\/+$/, '')}/stats`, {
    headers: { Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(30000),
  });
  if (!res.ok) throw new Error(`GET /stats returned HTTP ${res.status}: ${(await res.text()).slice(0, 300)}`);
  return res.json();
}

function runLoadTest(cfg, { url, users, seconds, reportJson, resultsCsv }) {
  const args = [
    path.join(__dirname, 'load-test.js'),
    `--ENV_FILE=${cfg._envFile === '(none)' ? '.env' : cfg._envFile}`,
    `--API_URL=${url}`,
    `--CONCURRENCY=${users}`,
    `--DURATION_SECONDS=${seconds}`,
    '--RAMP_UP_SECONDS=0',
    '--TARGET_RPS=0',
    '--MAX_REQUESTS=0',
    '--THINK_TIME_MS=0',
    '--START_DELAY_SECONDS=0',
    '--EXPECTED_STATUS=200',
    '--MAX_ERROR_RATE_PERCENT=100',
    `--REQUEST_TIMEOUT_MS=${cfg.REQUEST_TIMEOUT_MS}`,
    `--LOAD_GRANT_TYPE=${cfg.LOAD_GRANT_TYPE}`,
    `--REPORT_JSON=${reportJson ?? ''}`,
    `--RESULTS_CSV=${resultsCsv ?? ''}`,
  ];
  // A static token goes through the environment rather than the command line.
  const env = cfg.LOAD_GRANT_TYPE === 'static' ? { ...process.env, ACCESS_TOKEN: cfg.ACCESS_TOKEN } : process.env;
  const result = spawnSync(process.execPath, args, { stdio: 'inherit', env });
  if (result.status === 1) throw new Error('load-test.js failed (see the error above)');
}

async function main() {
  const { flags } = parseArgs(process.argv.slice(2));
  const cfg = loadConfig(flags, RUN_DEFAULTS);
  requireKeys(cfg, ['ISOLATED_URL', 'NON_ISOLATED_URL']);
  const scenarios = parseScenarios(cfg.SCENARIOS);
  const duration = Number(cfg.DURATION_SECONDS);
  const warmup = Number(cfg.WARMUP_SECONDS);
  const cooldownMs = Number(cfg.COOLDOWN_SECONDS) * 1000;

  const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  const outDir = path.resolve(cfg.OUTPUT_DIR, cfg.RUN_LABEL ? `${stamp}_${cfg.RUN_LABEL}` : stamp);
  fs.mkdirSync(path.join(outDir, 'runs'), { recursive: true });

  const runsTotal = scenarios.length * 2;
  const minutes = Math.ceil((runsTotal * (duration + cooldownMs / 1000) + 2 * warmup) / 60);
  console.log(`Isolation comparison: ${scenarios.length} scenarios x 2 variants, ${duration}s each, about ${minutes} min.`);
  console.log(`Results: ${outDir}`);

  const token = await getToken(cfg);
  console.log(`Token for /stats: ${mask(token)}`);
  const meta = {
    label: cfg.RUN_LABEL,
    startedAt: new Date().toISOString(),
    settings: Object.fromEntries(Object.keys(RUN_DEFAULTS).filter((k) => k !== 'ACCESS_TOKEN').map((k) => [k, cfg[k]])),
    variants: {},
    runs: [],
  };

  for (const v of VARIANTS) {
    const base = cfg[v.urlKey];
    const stats = await getStats(base, token);
    if (stats.variant !== v.name) {
      throw new Error(`${v.urlKey} points to the "${stats.variant}" variant, expected "${v.name}"`);
    }
    meta.variants[v.name] = { url: base, cpus: stats.cpus };
    console.log(`\n${v.name}: ${stats.cpus} CPU core(s) available. Warming up for ${warmup}s...`);
    if (warmup > 0) {
      runLoadTest(cfg, { url: workUrl(base, 'cpu', cfg), users: 4, seconds: Math.ceil(warmup / 2) });
      runLoadTest(cfg, { url: workUrl(base, 'io', cfg), users: 4, seconds: Math.ceil(warmup / 2) });
    }
  }

  let runNo = 0;
  for (const [i, s] of scenarios.entries()) {
    // Alternate which variant goes first.
    const order = i % 2 === 0 ? VARIANTS : [...VARIANTS].reverse();
    for (const v of order) {
      runNo += 1;
      const base = cfg[v.urlKey];
      const name = `${s.id}_${v.name}`;
      console.log(`\n=== Run ${runNo}/${runsTotal}: ${s.work.toUpperCase()}, ${s.users} users, ${v.name} ===`);
      const before = (await getStats(base, token)).requestCounts[s.work] ?? 0;
      runLoadTest(cfg, {
        url: workUrl(base, s.work, cfg),
        users: s.users,
        seconds: duration,
        reportJson: path.join(outDir, 'runs', `${name}.json`),
        resultsCsv: path.join(outDir, 'runs', `${name}.csv`),
      });
      const after = (await getStats(base, token)).requestCounts[s.work] ?? 0;
      meta.runs.push({ scenario: s.id, work: s.work, users: s.users, variant: v.name, file: `runs/${name}.json`, countedByService: after - before });
      fs.writeFileSync(path.join(outDir, 'run-meta.json'), JSON.stringify(meta, null, 2));
      if (runNo < runsTotal && cooldownMs) await sleep(cooldownMs);
    }
  }

  meta.finishedAt = new Date().toISOString();
  fs.writeFileSync(path.join(outDir, 'run-meta.json'), JSON.stringify(meta, null, 2));
  const { markdown } = summarize(outDir);
  console.log(`\n${markdown}`);
  console.log(`Summary saved to ${path.join(outDir, 'summary.md')} (and summary.csv)`);
}

main().catch((err) => {
  console.error(`\nERROR: ${err.message}`);
  process.exit(1);
});
