# POC 8 — One Devant integration calling another in a different project

The simplest cross-project call: **Integration 1** in Project1 calls **Integration 2** in
Project2, which responds with JSON.

```
Client ──▶ Project1: Integration 1  (/hello, Public)
                │  API key (or OAuth token), through the Devant gateway
                ▼
           Project2: Integration 2  (/greeting, Organization) ──▶ JSON
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
call it, with a token. Project visibility wouldn't work here, because it only allows calls from
the same project.

## Responses

`GET /greeting?name=Provident` on Integration 2:
```json
{"message":"Hello, Provident!", "servedBy":"integration2", "project":"Project2", "timestamp":"2026-10-19T13:39:37Z"}
```

`GET /hello?name=Provident` on Integration 1:
```json
{"servedBy":"integration1", "project":"Project1",
 "integration2Response":{"message":"Hello, Provident!", "servedBy":"integration2", "project":"Project2", "timestamp":"…"}}
```

If Integration 2 can't be reached, Integration 1 returns `502` with
`{"message":"Integration 2 call failed", "reason":"…"}`.

## Deploy to Devant
Use the **Development** environment throughout.

1. **Integration 2 (Project2):** + Create → **Integration as API** → this repository, branch
   `poc08-project2`, directory `project2/integration2`. **Build**, then **Deploy**. Check that its endpoint shows
   **Organization** visibility.
2. **Integration 1 (Project1):** + Create → **Integration as API** → branch `poc08-project1`,
   directory `project1/integration1`. **Build** only.
3. **Connection:** in Integration 1 → **Connections → + Create** → select Integration 2 (listed
   because it's Organization-visible). Keep the connection's details open, with **Development**
   selected.
4. **Configure:** in Integration 1 → **Deploy → Configure**, set the values the connection shows.
   Optional parameters are only passed when their switch is **on**.

   | Connection shows | Configurable |
   |---|---|
   | `ServiceURL` | `integration2Url` (required) |
   | `ChoreoAPIKey` | `choreoApiKey` (**secret**) — sent in the `Choreo-API-Key` header |

   If the connection shows OAuth values instead (token URL, consumer key, consumer secret), set
   `tokenUrl`, `consumerKey` and `consumerSecret`. Only use values from this connection, not keys
   from a Developer Portal application.

5. **Deploy** Integration 1. Its log shows
   `integration1 started … auth="api-key"` (or `auth="oauth2-client-credentials"`).
6. **Test:** Integration 1's Test console, or
   `curl -H "Authorization: Bearer <token>" "<integration1 invoke URL>?name=Provident"`.
   The invoke URL (ending in `/v1.0`) already maps to `/hello`, so don't add `/hello` to it.

### If Integration 1 returns 502 with `upstreamStatus` 401
Integration 2's gateway rejected the credentials. `upstreamBody.code` says why: `900902` none were
sent (check the startup log's `auth=`), `900901` they're invalid (wrong key, or from another
environment or application).

### If Integration 1 returns "SSL connection failed … SSLHandshakeException"
Integration 1 reached Integration 2's internal gateway but doesn't trust its TLS certificate,
for example because it's signed by a private CA. Two optional configurables on Integration 1:

| Configurable | Default | Use |
|---|---|---|
| `integration2CaCertFile` | *(empty)* | Path to the CA certificate (PEM) that signed the gateway's certificate. Mount the PEM file in Devant (Configs & Secrets → file mount) and set its path here. This is the proper fix. |
| `integration2VerifyTls` | `true` | `false` skips certificate checks. **Diagnosis only**: if the call then works, the problem is certificate trust. Set it back to `true` afterwards. |

The startup log shows which is in use: `tls="default trust store"`, `"custom CA"` or
`"NOT VERIFIED"` (with a warning).

Endpoints and visibility are declared in each `.choreo/component.yaml`. If Devant doesn't show
the endpoint after deployment, add it in the console: base path `/greeting` (or `/hello`),
port `9090`, type REST, with the visibility above.

## Run locally
Ballerina 2201.12.8 or later, Java 21.

```bash
(cd project2/integration2 && bal run -- -Cport=9092)
(cd project1/integration1 && bal run -- -Cintegration2Url=http://localhost:9092/greeting)
curl "http://localhost:9090/hello?name=Provident"
```
Locally there's no gateway, so no credentials are needed. Leave `choreoApiKey` and `consumerKey` empty.
