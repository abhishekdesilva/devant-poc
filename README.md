# POC 4 — OAuth2 token + Bijira API invocation (JS client & JMeter)

Covers the customer's three asks with two configurable tools:

| Ask | Tool |
|---|---|
| Fetch a token (client credentials) from Bijira, invoke the Bijira API, verify the call in the Devant logs | `js-client` → `client-credentials` |
| Authorization code grant: `/authorize` → code → token endpoint → extract the JWT from the response | `js-client` → `auth-code` |
| JavaScript client that fetches a token from `api.providentnj.com/oauth2/token` with the authorization code grant and invokes an API hosted in the PDP | `js-client` → `auth-code` with `API_URL` set to the PDP API |
| Repeat the API invocation under load | `jmeter/bijira-oauth-api-test.jmx` |

All endpoints, credentials, and API details are **configuration** — nothing is hard-coded, so the
customer's values drop straight in once shared.

```
04-oauth-client-poc/
├── js-client/
│   ├── oauth-client.js        # Node 18+, zero dependencies
│   └── .env.example
├── jmeter/
│   ├── bijira-oauth-api-test.jmx
│   └── test.properties.example
└── mock-server/
    └── mock-oauth-server.js   # local stand-in for the key manager + API, for dry runs
```

---

## 1. JavaScript client

```bash
cd js-client
cp .env.example .env           # fill in what the customer shares
node oauth-client.js client-credentials
node oauth-client.js auth-code
node oauth-client.js decode <jwt>
```

Any setting can be overridden per run: `node oauth-client.js auth-code --SCOPE="openid email" --API_URL=https://...`.

### What each flow does
**`client-credentials`**
1. `POST TOKEN_URL` with `grant_type=client_credentials` (client auth: Basic header, form body, or none).
2. Decodes the access token if it's a JWT; verifies signature/`exp`/`iss`/`aud` when `JWKS_URL` is set.
3. Calls `API_URL` with `Authorization: Bearer …` and a fresh `X-Correlation-ID` (plus `X-Forwarded-For` if `FORWARDED_FOR` is set).
4. Prints the correlation ID and timestamp to search for in **Devant → Observability → Logs**.

**`auth-code`**
1. Builds the `/authorize` URL with `state` and PKCE (S256), opens the browser.
2. Captures the code on the local `REDIRECT_URI` (e.g. `http://localhost:8080/callback`), checks `state`.
   If the registered redirect URI isn't a local http address, it asks you to paste the URL the browser landed on.
3. Exchanges the code at `TOKEN_URL`.
4. **Extracts and decodes the JWT(s)** from the response — `access_token` and, if `openid` is in `SCOPE`, `id_token`.
5. Invokes `API_URL` (e.g. the PDP-hosted API) and prints the Devant correlation ID.

`TOKEN_OUTPUT_FILE=tokens.json` saves the token response so the access/refresh token can be fed into JMeter.

### Key settings
| Setting | Purpose |
|---|---|
| `TOKEN_URL`, `AUTHORIZE_URL` | Key manager endpoints (customer has mentioned both `api-dev.providentnj.com` and `api.providentnj.com/oauth2/...` — confirm per env) |
| `CLIENT_ID`, `CLIENT_SECRET`, `TOKEN_AUTH_METHOD` | `basic` (default) / `body` / `none` (public client + PKCE) |
| `SCOPE` | Add `openid` to get an `id_token` |
| `REDIRECT_URI`, `USE_PKCE` | Must match the OAuth app registration exactly |
| `JWKS_URL`, `EXPECTED_ISSUER`, `EXPECTED_AUDIENCE` | Optional JWT verification |
| `API_URL`, `API_METHOD`, `API_BODY`, `API_EXTRA_HEADERS` | API to invoke |
| `CORRELATION_HEADER`, `FORWARDED_FOR` | Devant log lookup / XFF test |

Corporate TLS interception or a private CA: run with `NODE_EXTRA_CA_CERTS=/path/to/ca.pem`.

---

### Load test (JavaScript)
`js-client/load-test.js` drives concurrent virtual users against `API_URL` with automatic token
renewal, live progress, latency percentiles, and per-request CSV output. The customer-facing copy
with full guidance lives in `../share/bijira-js-load-test/` (README there documents every setting).
```bash
node js-client/load-test.js --CONCURRENCY=20 --DURATION_SECONDS=60 --TARGET_RPS=50
```

## 2. JMeter plan

```bash
cd jmeter
cp test.properties.example test.properties   # fill in
# functional smoke run (1 thread, 1 call, logs the correlation ID)
jmeter -n -t bijira-oauth-api-test.jmx -q test.properties -JLOG_EVERY_REQUEST=true -l smoke.jtl
# load run
jmeter -n -t bijira-oauth-api-test.jmx -q test.properties \
  -JTHREADS=50 -JRAMP_UP=60 -JLOOPS=-1 -JDURATION=900 -l results.jtl -e -o report/
```

Structure:
- **setUp thread group** — obtains one access token (per `GRANT_TYPE`), logs the decoded JWT claims to
  `jmeter.log`, and publishes it as the `ACCESS_TOKEN` property. Stops the test if no token is obtained.
- **API load thread group** — invokes `API_URL` with the shared token, a per-request correlation ID,
  optional `X-Forwarded-For`, and asserts `EXPECTED_STATUS`. Non-matching responses are logged with
  their correlation ID so they can be traced in Devant.

### Choosing `GRANT_TYPE` for load
The authorization code grant needs an interactive browser login, and codes are single-use — so it
can't be replayed by JMeter threads. Options:

| `GRANT_TYPE` | When |
|---|---|
| `client_credentials` | Default for gateway/backend load (no end-user context) |
| `static` | Run the JS client `auth-code` flow first, pass `-JSTATIC_ACCESS_TOKEN=$(jq -r .access_token tokens.json)` — end-user token, real claims |
| `refresh_token` | Same, but JMeter mints a fresh access token from `-JREFRESH_TOKEN=$(jq -r .refresh_token tokens.json)` |
| `authorization_code` | Only to exercise the token endpoint once with a freshly captured code |

Notes:
- The token is fetched once and shared. Make sure its lifetime exceeds `DURATION`, or the run will
  start returning 401s.
- `sample_variables=CORRELATION_ID` (set in `test.properties.example`) writes the correlation ID into
  each row of `results.jtl`.
- The *View Results Tree* listener is disabled by default; enable it only for debugging in the GUI.
- Load tests against Bijira/Devant SaaS should be agreed with WSO2 in advance (see the load-testing
  questions shared with the customer).

---

## 3. Dry run against the local mock

```bash
node mock-server/mock-oauth-server.js        # http://localhost:9443, client test-client / test-secret

# JS client
node js-client/oauth-client.js auth-code \
  --TOKEN_URL=http://localhost:9443/oauth2/token --AUTHORIZE_URL=http://localhost:9443/oauth2/authorize \
  --CLIENT_ID=test-client --CLIENT_SECRET=test-secret --SCOPE="openid email" \
  --JWKS_URL=http://localhost:9443/oauth2/jwks --API_URL=http://localhost:9443/api/orders

# JMeter
jmeter -n -t jmeter/bijira-oauth-api-test.jmx -JTOKEN_URL=http://localhost:9443/oauth2/token \
  -JCLIENT_ID=test-client -JCLIENT_SECRET=test-secret -JAPI_URL=http://localhost:9443/api/orders \
  -JLOG_EVERY_REQUEST=true -l /tmp/smoke.jtl
```

The mock auto-approves `/authorize` and prints a Devant-style log line (`correlationId=… xff=… sub=…`)
for every API call, so the end-to-end trace can be demonstrated without real credentials.

---

## Still needed from the customer
- Confirmed token / authorize / JWKS URLs per environment (`api-dev` vs `api`, `/token` vs `/oauth2/token`), and which IdP backs them.
- Client ID/secret per grant type, and the registered redirect URI (ideally a `http://localhost:<port>/callback` for the test app).
- The PDP-hosted API URL, method, and a sample request.
- A test user for the authorization code flow.
- Which JWT they want extracted (access token, `id_token`, or the backend JWT Devant receives) and whether it must be signature-verified.
- Access to the Devant logs, and confirmation the integration logs the correlation header.
