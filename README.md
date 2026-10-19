# POC 8 — One Devant integration calling another in a different project

The simplest cross-project call: **Integration 1** in Project1 calls **Integration 2** in
Project2, which responds with JSON.

```
Client ──▶ Project1: Integration 1  GET /hello      (Public)
                │  API key (or OAuth token), through the Devant gateway
                ▼
           Project2: Integration 2  GET /greeting   (Organization) ──▶ JSON
```

```
08-devant-cross-project-call/
├── project1/integration1/   # GET /hello?name=…    calls Integration 2, returns its reply
└── project2/integration2/   # GET /greeting?name=… returns a JSON greeting
```

**Git branches** in the `devant-poc` repository: `poc08-project1` holds `project1/` and
`poc08-project2` holds `project2/`. In Devant, select the branch that matches the component's
project.

Integration 2's endpoint has **Organization** visibility: any integration in the organization can
call it, with credentials. Project visibility wouldn't work here, because it only allows calls
from the same project.

## URLs and responses
Both services use the base path `/`, so the resource name follows the Devant invoke URL
(`…/<project>/<component>/v1.0`):

| Integration | Invoke | Service path |
|---|---|---|
| Integration 1 | `…/project1/integration1/v1.0/hello?name=Provident` | `/hello` |
| Integration 2 | `…/project2/integration2/v1.0/greeting?name=Provident` | `/greeting` |

Integration 2:
```json
{"message":"Hello, Provident!", "servedBy":"integration2", "project":"Project2", "timestamp":"2026-10-19T16:55:40Z"}
```

Integration 1:
```json
{"servedBy":"integration1", "project":"Project1",
 "integration2Response":{"message":"Hello, Provident!", "servedBy":"integration2", "project":"Project2", "timestamp":"…"}}
```

If the call to Integration 2 fails, Integration 1 returns `502` with
`{"message":"Integration 2 call failed", "reason":"…"}`. If Integration 2 or its gateway answered
with an error, the response also has `upstreamStatus` and `upstreamBody`.

Integration 2 logs `greeting request received` for each request, so its logs show whether a call
arrived.

## Integration 1 settings (Configs & Secrets)
Integration 1 reads its settings from **environment variables**. In Devant: Integration 1 →
**Configs & Secrets** → **+ Create**, **Mount: Environment Variables**, for the environment you
deploy to. Use the values of the Connection to Integration 2.

| Environment variable | Value | Type |
|---|---|---|
| `INTEGRATION2_URL` | Connection → `ServiceURL` (**required**) | Config |
| `CHOREO_API_KEY` | Connection → `ChoreoAPIKey`, sent in the `Choreo-API-Key` header | **Secret** |
| `TOKEN_URL`, `CONSUMER_KEY`, `CONSUMER_SECRET` | Only for OAuth connections (token URL, consumer key, consumer secret). Use instead of `CHOREO_API_KEY`. | Config, **Secret**, **Secret** |
| `INTEGRATION2_TIMEOUT_SECONDS` | How long to wait for Integration 2. Default `30`, below the gateway's 60 s. | Config |
| `INTEGRATION2_CA_CERT_FILE` | Path to a mounted PEM file, if Integration 2's gateway uses a private CA (see below) | Config |
| `INTEGRATION2_VERIFY_TLS` | `false` skips certificate checks. **Diagnosis only.** | Config |

Use these names exactly: upper case, with underscores. Ballerina configurables (Deploy →
Configure) aren't used for these settings. Environment variables are only read when Integration
1 starts, so **redeploy** after changing them.

The startup log shows what's in use, without any secret values:
```
integration1 started  integration2Url="https://…"  auth="api-key"  tls="default trust store"  timeoutSeconds=30
```
If `INTEGRATION2_URL` is missing, Integration 1 stops at startup with a message saying so.

## Deploy to Devant
Use the **Development** environment throughout.

1. **Integration 2 (Project2):** + Create → **Integration as API** → this repository, branch
   `poc08-project2`, directory `project2/integration2`. **Build**, then **Deploy**. Check that its
   endpoint shows **Organization** visibility.
2. **Integration 1 (Project1):** + Create → **Integration as API** → branch `poc08-project1`,
   directory `project1/integration1`. **Build** only.
3. **Connection:** in Integration 1 → **Connections → + Create** → select Integration 2 (listed
   because it's Organization-visible). Open its details with **Development** selected.
4. **Configs & Secrets:** create the environment variables in the table above from the
   connection's values: at least `INTEGRATION2_URL` and `CHOREO_API_KEY`.
5. **Deploy** Integration 1, and check the startup log line.
6. **Test:** Integration 1's Test console, or
   `curl -H "Authorization: Bearer <token>" "<integration1 invoke URL>/hello?name=Provident"`.

### If Integration 1 returns 502 with `upstreamStatus` 401
Integration 2's gateway rejected the credentials. `upstreamBody.code` says why: `900902` none were
sent (check the startup log's `auth=`), `900901` they're invalid (wrong key, or from another
environment or application).

### If Integration 1 returns "did not respond within … seconds"
Integration 2 didn't answer in time. Check that its deployment is active and whether its log shows
`greeting request received`. The first call after a period of inactivity can be slow if Devant has
scaled Integration 2 down; call again.

### If Integration 1 returns "SSL connection failed … SSLHandshakeException"
Integration 1 reached Integration 2's internal gateway but doesn't trust its TLS certificate,
for example because it's signed by a private CA.
- **To confirm:** set `INTEGRATION2_VERIFY_TLS` = `false` and redeploy. If the call then works, the
  problem is certificate trust. Remove the variable afterwards.
- **To fix:** mount the CA certificate (PEM) as a file in Configs & Secrets (file mount), and set
  `INTEGRATION2_CA_CERT_FILE` to its path.

The startup log shows `tls="default trust store"`, `"custom CA"` or `"NOT VERIFIED"` (with a
warning).

Endpoints and visibility are declared in each `.choreo/component.yaml`. If Devant doesn't show
the endpoint after deployment, add it in the console: base path `/`, port `9090`, type REST, with
the visibility above.

## Run locally
Ballerina 2201.12.8 or later, Java 21.

```bash
(cd project2/integration2 && bal run -- -Cport=9092)
(cd project1/integration1 && INTEGRATION2_URL=http://localhost:9092 bal run)
curl "http://localhost:9090/hello?name=Provident"
```
Locally there's no gateway, so no credentials are needed.
