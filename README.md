# POC 10: Load test of a Ballerina service with and without `isolated`

This POC measures what `isolated` changes for a Ballerina integration under load. The same
service is deployed twice in Devant:

| Integration | Shared request counter | What the compiler does |
|---|---|---|
| **non-isolated** | Plain module-level variable | Reports `concurrent calls will not be made to this method`; the listener handles requests **one at a time** |
| **isolated** | `isolated` variable, used only inside `lock` | Proves the access is safe; the listener handles requests **in parallel** on all available cores |

Everything else is identical: the two `service.bal` files differ only in the lines marked
`DIFFERENCE`, and `types.bal` and the API are the same.

Each integration has two kinds of work, so the test shows where `isolated` matters and where it
doesn't:

| Resource | Work | Represents |
|---|---|---|
| `GET /cpu?iterations=10000000` | Integer arithmetic, no memory allocation or library calls | Work that keeps the CPU busy, such as calculations |
| `GET /io?ms=200` | Waits 200 ms without using a thread | Calling another service or a database and waiting for the answer |
| `GET /stats` | Returns the variant, the **CPU cores available** to the integration, and the request counts | Checking the setup |

The load test sends the same scenarios to both integrations, one after the other, and writes a
side-by-side summary.

```
10-ballerina-isolation-load-test/
├── devant/
│   ├── non-isolated/          Integration as API: plain shared variable
│   │   ├── service.bal        the service (DIFFERENCE lines vs isolated/)
│   │   ├── types.bal          identical in both
│   │   ├── openapi.yaml       API definition, so Devant lists the resources
│   │   └── .choreo/component.yaml   port 9090, Public
│   └── isolated/              Integration as API: isolated shared variable + lock
├── load-test/
│   ├── run-comparison.js      runs every scenario against both integrations, writes the summary
│   ├── summarize.js           rebuilds a summary from a results folder
│   ├── load-test.js           the load generator (same tool as the earlier Bijira load test)
│   ├── oauth-client.js        token handling
│   └── .env.example           settings template
└── results/                   results of the runs, one folder per run
```

## Results

See [Results summary](#results-summary) below, and the `results/` folder for every run's report
(`runs/*.json`), per-request data (`runs/*.csv`) and summary (`summary.md`, `summary.csv`).

---

## 1. Before you start
- **Agree the test window with WSO2.** Devant is a shared platform. Share the date, time and
  expected load before running, so the traffic isn't throttled or treated as an attack.
- **Use a non-production environment** (Development).
- **Node.js 18 or newer** on the machine running the test. There's nothing to install. On a corporate
  network that inspects HTTPS (for example Zscaler), use Node.js 22.15 or newer and set
  `NODE_OPTIONS=--use-system-ca`, as in the earlier load test.
- **Ballerina 2201.12.8 and Java 21**, only if you want to run the integrations on your machine.

## 2. Deploy the two integrations
Push this folder to a Git repository that Devant can access. Then, in one Devant project:

1. **+ Create → Integration as API**, directory `devant/non-isolated`. Name it, for example,
   `isolation-demo-non-isolated`. **Build** and **Deploy** to Development. If Devant shows an
   optional `port` setting, leave it at its default (9090).
2. Repeat with directory `devant/isolated`, for example `isolation-demo-isolated`.
3. On both, keep the same settings so the comparison is fair:
   - the **same environment** (Development);
   - **one replica**, with autoscaling off;
   - the **same CPU and memory** allocation.
4. Check both endpoints are **Public** and list `/cpu`, `/io` and `/stats`.
5. Check the runtime logs of each. They show, for example:
   ```
   isolation demo started  variant="non-isolated"  cpus=2
   ```
   `cpus` is the number of CPU cores the integration can use. `isolated` can only run requests in
   parallel up to that number, so it largely decides the result (see
   [Reading the results](#5-reading-the-results)).

## 3. Get credentials for the load test
1. Set both APIs to **Published** (Lifecycle).
2. In the Devant Developer Portal, create an application, for example `isolation-load-test`.
3. **Subscribe it to both APIs** with the **Unlimited** subscription policy, so rate limiting
   doesn't cap the test.
4. **Generate keys** for the environment you deployed to. Note the token URL, consumer key and
   consumer secret.

## 4. Run the comparison
```bash
cd load-test
cp .env.example .env          # Windows: Copy-Item .env.example .env
```
Fill in `.env`:

| Setting | Value |
|---|---|
| `NON_ISOLATED_URL` | Invoke URL of `isolation-demo-non-isolated`, ending in `/v1.0` |
| `ISOLATED_URL` | Invoke URL of `isolation-demo-isolated`, ending in `/v1.0` |
| `TOKEN_URL`, `CLIENT_ID`, `CLIENT_SECRET` | From step 3 |
| `RUN_LABEL` | Optional, for example `devant` |

Then run:
```bash
node run-comparison.js
```
With the default settings this takes about 12 minutes:
- 4 scenarios × 2 integrations, 60 s each, with a 10 s pause between runs;
- a 20 s warm-up per integration first, which isn't included in the results.

It checks each URL points to the expected variant before starting, then prints progress. At the
end it prints the summary and saves everything under `results/<date>_<label>/`.

**Settings you may want to change** (in `.env`, or per run as `--KEY=value`):

| Setting | Default | Meaning |
|---|---|---|
| `SCENARIOS` | `cpu:1,cpu:10,cpu:25,io:25` | Work type and number of concurrent users for each scenario |
| `DURATION_SECONDS` | `60` | Length of each run |
| `CPU_ITERATIONS` | `10000000` | Size of the CPU work per request |
| `IO_MS` | `200` | Length of the I/O wait per request |

## 5. Reading the results
`summary.md` starts with a comparison table, one row per scenario:

| Column | Meaning |
|---|---|
| Throughput non-isolated / isolated | Requests per second each integration handled |
| Isolated vs non-isolated | Throughput of isolated divided by non-isolated. **2.0×** means twice as many requests per second |
| p95 non-isolated / isolated | 95% of requests completed within this time |

What to expect:
- **CPU, 1 user:** about the same. With one request at a time, there's nothing to run in parallel.
- **CPU, 10 and 25 users:** `isolated` handles more requests per second, with lower response
  times, **up to the number of CPU cores** the integration has (`cpus`). With 1 core, there's
  little or no difference; with 2 cores, up to about 2×; and so on.
- **I/O, 25 users:** about the same. While a request waits for another service, Ballerina runs
  other requests on the same thread, so the waits overlap even without `isolated`.
- **"Counted by service"** equals the successful requests in both variants. Both are correct: the
  non-isolated one is correct because it never runs requests in parallel.

All response times include the Devant gateway and the network between the test machine and
Devant, which add the same fixed time to both integrations.

### Not all CPU work scales the same way
`/cpu` is pure computation on purpose, so the test shows the effect of `isolated` alone. Real
code often spends part of its time elsewhere, which limits how much it gains from running in
parallel, with or without `isolated`. While preparing this test we measured three kinds of CPU
work in a service that already runs requests in parallel (14 cores, 1 user compared with 10):

| Work | 1 user | 10 users | Scaling |
|---|---|---|---|
| Integer arithmetic (what `/cpu` does) | 15.5 req/s | 137.3 req/s | 8.9× |
| 200,000 separate `crypto:hashSha256` calls per request | 23.2 req/s | 46.0 req/s | 2.0×, limited by contention inside the library |
| Data mapping creating ~1.6 GB of short-lived objects every 0.2 s | 5.5 req/s | 4.0 req/s | None, limited by memory allocation and garbage collection |

So `isolated` is what allows parallelism, but how much a given integration gains depends on its
work. To know for a specific integration, load-test that integration.

## 6. Run it on your machine (optional)
```bash
cd devant/non-isolated && bal run -- -Cport=9091      # terminal 1
cd devant/isolated && bal run -- -Cport=9092          # terminal 2

cd load-test                                          # terminal 3
node run-comparison.js --NON_ISOLATED_URL=http://localhost:9091 --ISOLATED_URL=http://localhost:9092 \
     --LOAD_GRANT_TYPE=static --ACCESS_TOKEN=local --RUN_LABEL=local
```
No token is needed locally; any value works for `ACCESS_TOKEN`.

To see how the number of cores changes the result, limit the cores Java uses, for example to 2:
```bash
bal build
java -XX:ActiveProcessorCount=2 -jar target/bin/isolation_demo_isolated.jar -Cport=9092
```
This only changes how many cores Java *reports*, which sets how many worker threads Ballerina
uses; the threads can still run on any of the machine's cores. It's a fair approximation for 2 or
more cores, but not for 1 (Ballerina still uses two worker threads). For a true limit, run the
integration in a container with a CPU limit.

---

## Results summary
### Local baseline (Apple M4 Pro, 14 cores)
Both integrations on the same machine as the load generator, 30 s per run. Full reports are in
`results/2026-10-26T12-09-20_local-14-cores/` and `results/2026-10-26T12-14-42_local-2-cores/`.

**All 14 cores:**

| Scenario | Users | Non-isolated (req/s) | Isolated (req/s) | Isolated vs non-isolated | p95 non-isolated | p95 isolated |
|---|---|---|---|---|---|---|
| CPU | 1 | 32.0 | 32.0 | 1.0× | 35 ms | 35 ms |
| CPU | 10 | 32.5 | 273.9 | **8.4×** | 341 ms | 43 ms |
| CPU | 25 | 32.4 | 331.4 | **10.2×** | 882 ms | 130 ms |
| I/O | 25 | 117.8 | 115.4 | 1.0× | 225 ms | 227 ms |

**Java limited to 2 cores** (`-XX:ActiveProcessorCount=2`):

| Scenario | Users | Non-isolated (req/s) | Isolated (req/s) | Isolated vs non-isolated | p95 non-isolated | p95 isolated |
|---|---|---|---|---|---|---|
| CPU | 1 | 32.0 | 31.7 | 1.0× | 35 ms | 36 ms |
| CPU | 10 | 32.6 | 63.8 | **2.0×** | 397 ms | 171 ms |
| CPU | 25 | 31.9 | 63.6 | **2.0×** | 1190 ms | 440 ms |
| I/O | 25 | 117.0 | 114.5 | 1.0× | 226 ms | 228 ms |

What this shows:
- **The non-isolated integration stays at about 32 req/s however many users there are.** That's one
  request at a time (each takes about 31 ms). Extra users only wait longer.
- **The isolated integration scales with the cores:** about 8–10× with 14 cores and 2× with 2 cores,
  and its response times stay much lower under load.
- **With one user, or with work that waits on other services (I/O), there's no difference.**
- **Every request was counted correctly by both integrations**, with no errors.

### Devant
To be added after running the comparison against the two integrations deployed in Devant. The
`cpus` value they report sets the upper limit of the gain.
