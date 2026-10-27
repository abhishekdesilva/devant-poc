# Isolation load test results: local-2-cores

- Run: 2026-10-26T12:14:42.058Z to 2026-10-26T12:20:00.259Z
- Each run: 30s, users sending requests back to back (no rate cap, no think time)
- CPU work: `GET /cpu?iterations=10000000`; I/O work: `GET /io?ms=200`
- non-isolated: 2 CPU core(s) available to the integration
- isolated: 2 CPU core(s) available to the integration

## Comparison

| Scenario | Users | Throughput non-isolated (req/s) | Throughput isolated (req/s) | Isolated vs non-isolated | p95 non-isolated (ms) | p95 isolated (ms) |
|---|---|---|---|---|---|---|
| CPU | 1 | 32 | 31.7 | **1.0×** | 35.4 | 35.7 |
| CPU | 10 | 32.6 | 63.8 | **2.0×** | 396.5 | 171.1 |
| CPU | 25 | 31.9 | 63.6 | **2.0×** | 1190.3 | 440.4 |
| IO | 25 | 117 | 114.5 | **1.0×** | 226.2 | 227.6 |

## All runs

| Scenario | Users | Variant | Requests | Errors | Throughput (req/s) | Avg (ms) | p50 (ms) | p95 (ms) | p99 (ms) | Max (ms) | Counted by service |
|---|---|---|---|---|---|---|---|---|---|---|---|
| CPU | 1 | non-isolated | 961 | 0 (0%) | 32 | 31.2 | 30.4 | 35.4 | 38.9 | 56.6 | 961 |
| CPU | 1 | isolated | 953 | 0 (0%) | 31.7 | 31.5 | 30.6 | 35.7 | 39.3 | 57.1 | 953 |
| CPU | 10 | isolated | 1924 | 0 (0%) | 63.8 | 156.2 | 152.9 | 171.1 | 186 | 204.6 | 1924 |
| CPU | 10 | non-isolated | 986 | 0 (0%) | 32.6 | 305.6 | 290.7 | 396.5 | 415.1 | 507.8 | 986 |
| CPU | 25 | non-isolated | 977 | 0 (0%) | 31.9 | 775.5 | 717.7 | 1190.3 | 1362.3 | 1425 | 977 |
| CPU | 25 | isolated | 1933 | 0 (0%) | 63.6 | 390.3 | 395 | 440.4 | 458.3 | 472.4 | 1933 |
| IO | 25 | isolated | 3450 | 0 (0%) | 114.5 | 218.2 | 218.2 | 227.6 | 234.2 | 258.1 | 3450 |
| IO | 25 | non-isolated | 3531 | 0 (0%) | 117 | 213.5 | 212.4 | 226.2 | 234.1 | 264.5 | 3531 |

"Counted by service" is how many requests the integration's shared counter recorded during the run.
It should equal the successful requests in both variants: the non-isolated variant is correct but
serialised, and the isolated variant is correct and parallel.
