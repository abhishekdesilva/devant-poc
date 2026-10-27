# Isolation load test results: local-14-cores

- Run: 2026-10-26T12:09:20.622Z to 2026-10-26T12:14:37.775Z
- Each run: 30s, users sending requests back to back (no rate cap, no think time)
- CPU work: `GET /cpu?iterations=10000000`; I/O work: `GET /io?ms=200`
- non-isolated: 14 CPU core(s) available to the integration
- isolated: 14 CPU core(s) available to the integration

## Comparison

| Scenario | Users | Throughput non-isolated (req/s) | Throughput isolated (req/s) | Isolated vs non-isolated | p95 non-isolated (ms) | p95 isolated (ms) |
|---|---|---|---|---|---|---|
| CPU | 1 | 32 | 32 | **1.0×** | 35.3 | 35.4 |
| CPU | 10 | 32.5 | 273.9 | **8.4×** | 340.9 | 42.8 |
| CPU | 25 | 32.4 | 331.4 | **10.2×** | 881.9 | 130.3 |
| IO | 25 | 117.8 | 115.4 | **1.0×** | 224.6 | 226.5 |

## All runs

| Scenario | Users | Variant | Requests | Errors | Throughput (req/s) | Avg (ms) | p50 (ms) | p95 (ms) | p99 (ms) | Max (ms) | Counted by service |
|---|---|---|---|---|---|---|---|---|---|---|---|
| CPU | 1 | non-isolated | 960 | 0 (0%) | 32 | 31.2 | 30.3 | 35.3 | 38.9 | 54.6 | 960 |
| CPU | 1 | isolated | 960 | 0 (0%) | 32 | 31.2 | 30.4 | 35.4 | 39.3 | 55 | 960 |
| CPU | 10 | isolated | 8227 | 0 (0%) | 273.9 | 36.5 | 35.3 | 42.8 | 50.4 | 86.2 | 8227 |
| CPU | 10 | non-isolated | 984 | 0 (0%) | 32.5 | 306.3 | 300.8 | 340.9 | 358.1 | 475.9 | 984 |
| CPU | 25 | non-isolated | 979 | 0 (0%) | 32.4 | 770 | 770.8 | 881.9 | 1403.9 | 1463.7 | 979 |
| CPU | 25 | isolated | 9962 | 0 (0%) | 331.4 | 75.3 | 68.8 | 130.3 | 219.4 | 465.8 | 9962 |
| IO | 25 | isolated | 3475 | 0 (0%) | 115.4 | 216.4 | 215.7 | 226.5 | 233.8 | 267.4 | 3475 |
| IO | 25 | non-isolated | 3554 | 0 (0%) | 117.8 | 212.1 | 210.8 | 224.6 | 231.3 | 258.1 | 3554 |

"Counted by service" is how many requests the integration's shared counter recorded during the run.
It should equal the successful requests in both variants: the non-isolated variant is correct but
serialised, and the isolated variant is correct and parallel.
