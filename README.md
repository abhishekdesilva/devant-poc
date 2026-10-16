# POC 7 — Calling one Devant integration from another

Shows how integrations call each other in Devant for each **endpoint visibility** level: within a
project, across projects, and through the public gateway.

```
Project1                                        Project2
┌──────────────────────────────────────┐        ┌────────────────────────────────────┐
│ caller-integration  (Public)         │        │                                    │
│   ├─▶ order-service (Project) ───────┤        │                                    │
│   ├──────────────────────────────────┼─────▶  │ customer-service  (Organization)   │
│   └──────────────────────────────────┼─────▶  │ inventory-service (Public)         │
└──────────────────────────────────────┘        └────────────────────────────────────┘
```

| Call | Target visibility | Who can call | Credentials the caller sends |
|---|---|---|---|
| Project1 caller → Project1 order-service | **Project** | Only components in the same project | None. Internal network, no gateway. |
| Project1 caller → Project2 customer-service | **Organization** | Any component in the organization | OAuth token (client credentials) or API key, checked by the internal gateway |
| Project1 caller → Project2 inventory-service | **Public** | Anyone, through the public gateway | OAuth token or API key, checked by the public gateway |

```
07-devant-inter-integration/
├── project1/
│   ├── caller-integration/   # Integration1: calls the three targets   (endpoint /demo, Public)
│   └── order-service/        # Integration2: same-project target       (endpoint /orders, Project)
├── project2/
│   ├── customer-service/     # cross-project target                    (endpoint /customers, Organization)
│   └── inventory-service/    # public target                           (endpoint /inventory, Public)
├── scripts/local-demo.sh     # runs everything locally and checks each path
└── tools/mock-oauth-server.js  # local OAuth token endpoint for the demo
```

Each service has a `.choreo/component.yaml` that declares its endpoint and visibility. You can also
change the visibility in the Devant console.

**Git branches:** in the `devant-poc` repository, each Devant project has its own branch.
Branch `project1` holds `project1/`, and branch `project2` holds `project2/`. When creating a
component in Devant, select the branch that matches its project, then the directory from the
table in section 2. The local demo needs both folders. On a `project1` checkout, add
`project2/` without switching branches:
`git fetch origin project2 && git archive origin/project2 project2 | tar -x`
(`project2/` then shows as untracked, so don't commit it to `project1`).

## How the caller is wired
A **Devant Connection** gives the caller each target's URL and, for Organization/Public targets,
credentials. The caller reads each value from a configurable (Configs & Secrets) or, if that's
empty, from an environment variable:

| Target | Configurables | Environment variables |
|---|---|---|
| order-service (Project) | `orderServiceUrl` | `ORDER_SERVICE_URL` |
| customer-service (Organization) | `customerServiceUrl`, `customerTokenUrl`, `customerClientId`, `customerClientSecret` **or** `customerApiKey` | `CUSTOMER_SERVICE_URL`, `CUSTOMER_TOKEN_URL`, `CUSTOMER_CLIENT_ID`, `CUSTOMER_CLIENT_SECRET`, `CUSTOMER_API_KEY` |
| inventory-service (Public) | `inventoryServiceUrl`, `inventoryTokenUrl`, `inventoryClientId`, `inventoryClientSecret` **or** `inventoryApiKey` | `INVENTORY_SERVICE_URL`, `INVENTORY_TOKEN_URL`, `INVENTORY_CLIENT_ID`, `INVENTORY_CLIENT_SECRET`, `INVENTORY_API_KEY` |

Authentication per target:
- **Client ID set:** OAuth client credentials. Ballerina's HTTP client fetches the token from the
  token URL and renews it automatically.
- **Otherwise, API key set:** sent in the `Choreo-API-Key` header.
- **Neither set:** no credentials, which is correct for Project visibility.
- **No URL:** the target is reported as `not configured`.

## API of the caller

| Call | What it does |
|---|---|
| `GET /demo/orders/{id}` | Calls order-service (Project) |
| `GET /demo/customers/{id}` | Calls customer-service (Organization) |
| `GET /demo/inventory/{sku}` | Calls inventory-service (Public) |
| `GET /demo/all?id=42` | Calls all three in parallel |

Each result shows the target, visibility, the authentication used, HTTP status, latency and the
target's response. Every target response includes a `caller` section showing what reached it:

```json
{"target":"customer-service", "visibility":"Organization", "auth":"oauth2-client-credentials",
 "ok":true, "status":200, "latencyMs":35.3,
 "response":{"service":"customer-service", "customer":{"id":"42", "name":"Ada Lovelace", "tier":"GOLD"},
             "caller":{"authorizationHeader":false, "apiKeyHeader":false,
                       "gatewayJwt":{"issuer":"…", "subject":"…", "audience":"…"}}}}
```

- `gatewayJwt` is present when the call came **through the Devant gateway** (Organization or
  Public). The gateway replaces the caller's token with its own signed JWT (`x-jwt-assertion`),
  which carries the verified caller identity (see POC 2). For Project calls it is `null`.
- `authorizationHeader` / `apiKeyHeader` show whether those headers reached the target. Locally
  they arrive as sent; behind the Devant gateway they're normally consumed by the gateway.

Token values are never logged or returned.

## 1. Run locally
Prerequisites: Ballerina 2201.12.8 or later, Java 21, Node.js 18 or later.

```bash
./scripts/local-demo.sh
```
It builds the four services, starts them with a mock OAuth server, wires the caller the way Devant
connections would (environment variables), and checks each path:

```
  PASS  order-service      Project       auth=none                       status=200  received: Authorization=false API-key=false
  PASS  customer-service   Organization  auth=oauth2-client-credentials  status=200  received: Authorization=true API-key=false
  PASS  inventory-service  Public        auth=api-key                    status=200  received: Authorization=false API-key=true
Result: all paths passed
```
It also shows the caller's response when a target is down. Run it with `KEEP_RUNNING=1` to leave
everything running and call `http://localhost:9090/demo/all` yourself.

There's no gateway locally, so the targets accept any request. On Devant, the gateway enforces the
visibility and credentials.

## 2. Deploy to Devant
Create two projects, **Project1** and **Project2**, in the same organization and environment.
Push this folder to a Git repository Devant can access.

1. **Deploy the targets first** (each is its own component; select its directory in the repository):

   | Component | Project | Directory | Endpoint visibility |
   |---|---|---|---|
   | order-service | Project1 | `project1/order-service` | Project |
   | customer-service | Project2 | `project2/customer-service` | Organization |
   | inventory-service | Project2 | `project2/inventory-service` | Public |

   Check the visibility on each component's endpoint after deployment.

2. **Create the caller** in Project1 from `project1/caller-integration`, and build it.

3. **Create a Connection for each target** in the caller (component → **Connections → + Create**):
   - **order-service:** only offered here because it's in the same project. Provides the
     service URL.
   - **customer-service:** listed because its visibility is Organization. Provides the service URL
     plus OAuth credentials (token URL, client ID, client secret) or an API key, depending on the
     connection type you choose.
   - **inventory-service:** Public. Same as above, through the public gateway.

   Devant shows the values each connection provides and the names it uses for them.

4. **Give the values to the caller** using either option:
   - **Configs & Secrets:** set the configurables in the table above with the connection's values.
     Store client secrets and API keys as **secrets**.
   - **Environment variables:** map the connection's values to the variable names in the table
     above. This keeps the values managed by the connection.

5. **Deploy the caller and test it:** Devant **Test** console, or
   `curl https://<caller-public-url>/demo/all?id=42` with the token the test console provides.
   Expected:
   - order-service: `200`, `gatewayJwt: null` (direct, inside the project)
   - customer-service and inventory-service: `200`, `gatewayJwt` filled in (through the gateway)

### Proving the visibility rules
- Remove the order-service connection and point `orderServiceUrl` at the order-service URL from
  **Project2** instead. The call fails, because Project visibility isn't reachable from another
  project.
- Clear the customer-service credentials. The call returns `401`, because the internal gateway
  requires a token or key.

## Notes
- **Environment-specific:** a connection resolves to the matching environment (Development to
  Development, Production to Production), so promotion needs no code change.
- **Least exposure:** use Project visibility for calls within a project, Organization for calls
  between projects, and Public only for external consumers, ideally through Bijira with OAuth
  (POC 5).
- Automations, scheduled jobs and event-triggered integrations have no endpoint. They can call
  other integrations this way, but can't be called themselves.
- Connection value names and the console steps can vary between Devant releases. Use the names
  Devant shows when you create the connection.
