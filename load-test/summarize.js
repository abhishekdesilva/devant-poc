#!/usr/bin/env node
// Builds summary.md and summary.csv from a results folder written by
// run-comparison.js. Runs automatically at the end of a comparison; run it by
// hand to rebuild a summary:  node summarize.js results/<folder>

const fs = require('fs');
const path = require('path');

const ratio = (a, b) => (b ? Math.round((a / b) * 10) / 10 : 0);

function loadRuns(dir) {
  const meta = JSON.parse(fs.readFileSync(path.join(dir, 'run-meta.json'), 'utf8'));
  const runs = meta.runs.map((r) => ({ ...r, report: JSON.parse(fs.readFileSync(path.join(dir, r.file), 'utf8')) }));
  return { meta, runs };
}

function summarize(dir) {
  const { meta, runs } = loadRuns(dir);
  const scenarios = [...new Set(runs.map((r) => r.scenario))];
  const find = (scenario, variant) => runs.find((r) => r.scenario === scenario && r.variant === variant);
  const s = meta.settings;

  const lines = [];
  lines.push(`# Isolation load test results${meta.label ? `: ${meta.label}` : ''}`, '');
  lines.push(`- Run: ${meta.startedAt} to ${meta.finishedAt ?? '(incomplete)'}`);
  lines.push(`- Each run: ${s.DURATION_SECONDS}s, users sending requests back to back (no rate cap, no think time)`);
  lines.push(`- CPU work: \`GET /cpu?iterations=${s.CPU_ITERATIONS}\`; I/O work: \`GET /io?ms=${s.IO_MS}\``);
  for (const [name, v] of Object.entries(meta.variants)) {
    lines.push(`- ${name}: ${v.cpus} CPU core(s) available to the integration`);
  }
  lines.push('', '## Comparison', '');
  lines.push('| Scenario | Users | Throughput non-isolated (req/s) | Throughput isolated (req/s) | Isolated vs non-isolated | p95 non-isolated (ms) | p95 isolated (ms) |');
  lines.push('|---|---|---|---|---|---|---|');
  for (const sc of scenarios) {
    const n = find(sc, 'non-isolated');
    const i = find(sc, 'isolated');
    if (!n || !i) continue;
    const factor = ratio(i.report.throughputRps, n.report.throughputRps);
    lines.push(
      `| ${n.work.toUpperCase()} | ${n.users} | ${n.report.throughputRps} | ${i.report.throughputRps} | ` +
        `**${factor.toFixed(1)}×** | ${n.report.latencyMs.p95} | ${i.report.latencyMs.p95} |`,
    );
  }

  lines.push('', '## All runs', '');
  lines.push('| Scenario | Users | Variant | Requests | Errors | Throughput (req/s) | Avg (ms) | p50 (ms) | p95 (ms) | p99 (ms) | Max (ms) | Counted by service |');
  lines.push('|---|---|---|---|---|---|---|---|---|---|---|---|');
  const csv = ['scenario,work,users,variant,requests,succeeded,failed,error_rate_percent,throughput_rps,avg_ms,p50_ms,p90_ms,p95_ms,p99_ms,max_ms,counted_by_service'];
  for (const r of runs) {
    const p = r.report;
    const l = p.latencyMs;
    lines.push(
      `| ${r.work.toUpperCase()} | ${r.users} | ${r.variant} | ${p.requests} | ${p.failed} (${p.errorRatePercent}%) | ` +
        `${p.throughputRps} | ${l.avg} | ${l.p50} | ${l.p95} | ${l.p99} | ${l.max} | ${r.countedByService} |`,
    );
    csv.push([r.scenario, r.work, r.users, r.variant, p.requests, p.succeeded, p.failed, p.errorRatePercent,
      p.throughputRps, l.avg, l.p50, l.p90, l.p95, l.p99, l.max, r.countedByService].join(','));
  }
  lines.push(
    '',
    '"Counted by service" is how many requests the integration\'s shared counter recorded during the run.',
    'It should equal the successful requests in both variants: the non-isolated variant is correct but',
    'serialised, and the isolated variant is correct and parallel.',
    '',
  );

  const markdown = lines.join('\n');
  fs.writeFileSync(path.join(dir, 'summary.md'), markdown);
  fs.writeFileSync(path.join(dir, 'summary.csv'), `${csv.join('\n')}\n`);
  return { markdown };
}

if (require.main === module) {
  const dir = process.argv[2];
  if (!dir) {
    console.error('Usage: node summarize.js <results folder>');
    process.exit(1);
  }
  console.log(summarize(path.resolve(dir)).markdown);
}

module.exports = { summarize };
