# POC 8 — One Devant integration calling another in a different project

The simplest cross-project call: **Integration 1** in Project1 calls **Integration 2** in
Project2, which responds with JSON.

```
Client ──▶ Project1: Integration 1  (/hello, Public)
                │  OAuth token, through the Devant gateway
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
   because it's Organization-visible) → OAuth. Keep the connection's details open.
4. **Configure:** in Integration 1 → **Deploy → Configure** (or Configs & Secrets), set:

   | Configurable | Value from the connection |
   |---|---|
   | `integration2Url` | Service URL (required) |
   | `tokenUrl` | Token URL |
   | `consumerKey` | Consumer key (**secret**) |
   | `consumerSecret` | Consumer secret (**secret**) |

5. **Deploy** Integration 1. Its log shows
   `integration1 started … auth="oauth2-client-credentials"`.
6. **Test:** Integration 1's Test console, or
   `curl -H "Authorization: Bearer <token>" "https://<integration1 URL>?name=Provident"`.

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
Locally there's no gateway, so no token is needed. Leave `consumerKey` empty.
