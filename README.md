# POC 6 — Read/write Microsoft SQL Server from Devant

A Devant integration (Ballerina) that exposes a SQL Server table as a REST API, with Bijira in
front for OAuth. It is built and tested against a local SQL Server 2022 in Docker, so it's ready
to point at Provident's database as soon as the connection details and network access are in
place. That switch is **configuration only**: no code changes.

```
Client ──OAuth──▶ Bijira API proxy ──▶ Devant: mssql_crud ──TLS──▶ SQL Server
```

```
06-devant-mssql-crud/
├── service.bal            # REST API, connection pool, transactions, health check
├── types.bal              # request/response records
├── Config.toml.example    # local configuration (Devant: Configs & Secrets)
├── db/init.sql            # schema, seed rows, least-privilege login
├── docker-compose.yml     # local SQL Server 2022 + one-shot init
├── .env.example           # local SQL Server passwords
└── scripts/api-test.sh    # end-to-end API test (local, Devant or Bijira URL)
```

## What it demonstrates
- **CRUD over REST** on `dbo.customers`, using parameterized queries only (no SQL injection).
- **Transactions:** every write and its `audit_log` row are committed together or rolled back
  together.
- **Connection pooling** with a bounded pool and timeouts.
- **Proper HTTP results:** `201` with `Location`, `400` for invalid input, `404` for a missing
  row, `409` for a duplicate email (SQL Server unique constraint), `503` from `/health` when the
  database is unreachable.
- **Least privilege:** the service connects as `poc_app`, which can read and write data only.
  It can't change the schema or perform administrative operations.
- **Safe logging:** logs contain record IDs, never customer data. `/health` doesn't expose
  connection details to callers.

## API

| Method & path | Body | Success | Errors |
|---|---|---|---|
| `GET /customers?limit=20&offset=0` | — | `200` list (limit 1–100) | `400` |
| `GET /customers/{id}` | — | `200` customer | `404` |
| `POST /customers` | `{"name","email","phone"?}` | `201` customer + `Location` | `400`, `409` |
| `PUT /customers/{id}` | `{"name","email","phone"?}` | `200` customer | `400`, `404`, `409` |
| `DELETE /customers/{id}` | — | `204` | `404` |
| `GET /health` | — | `200` `{"status":"UP","database":"UP"}` | `503` `{"status":"DOWN","database":"UNREACHABLE"}` |

Example:
```json
{"id":1, "name":"Ada Lovelace", "email":"ada@example.com", "phone":"+1-201-555-0101",
 "createdAt":"2026-10-13T17:28:53.540Z", "updatedAt":"2026-10-13T17:28:53.540Z"}
```

## 1. Run locally

Prerequisites: Ballerina 2201.12.8 (or later), Java 21, and Docker. On Apple silicon, SQL Server
runs under amd64 emulation: use Docker Desktop with Rosetta, or
`colima start --vm-type vz --vz-rosetta`.

```bash
cp .env.example .env                    # set your own local passwords
docker compose up -d                    # SQL Server + init (database, tables, seed, poc_app login)
docker compose logs mssql-init          # should end with "init complete"

cp Config.toml.example Config.toml      # set dbPassword to APP_PASSWORD from .env
bal run

./scripts/api-test.sh                   # 11 checks, expects "11 passed, 0 failed"
```

Clean up with `docker compose down`. The database is recreated on the next `up`.

## 2. Configuration

| Setting | Default | Purpose |
|---|---|---|
| `dbHost` | `localhost` | SQL Server host name or IP |
| `dbPort` | `1433` | SQL Server port |
| `dbName` | `pocdb` | Database name |
| `dbUser` | *(required)* | SQL authentication login |
| `dbPassword` | *(required)* | Password. **On Devant, store it as a secret.** |
| `dbInstance` | *(empty)* | Named instance, e.g. `SQLEXPRESS`. Empty for the default instance. |
| `dbEncrypt` | `true` | Encrypt the connection with TLS. Keep it on. |
| `dbTrustServerCertificate` | `false` | Skip server certificate validation. Only for local or self-signed databases. |
| `dbMaxOpenConnections` | `10` | Pool size: the maximum concurrent database connections from one replica |
| `dbConnectionTimeoutSeconds` | `10` | How long a request waits for a pooled connection |
| `dbLoginTimeoutSeconds` | `15` | Login timeout for new connections |
| `dbQueryTimeoutSeconds` | `30` | Maximum time for a single query |
| `servicePort` | `9090` | HTTP port of the service |

Timeouts are whole seconds (`int`). Ballerina 2201.12.8 crashes at startup if a `decimal`
configurable is given a whole number such as `15`, which is easy to do in a config UI.

## 3. Deploy to Devant
1. Push this folder to a Git repository that Devant can access.
2. Devant → **Create** → **Integration** (or Service) → select the repository and this directory.
   Devant detects the Ballerina project.
3. **Build**, then **Deploy** → set the configurables when prompted, with `dbPassword` as a
   **secret**. You can change them later under **Configs & Secrets**.
4. Test the endpoint URL:
   `BASE_URL=https://<devant-endpoint> TOKEN=<token if required> ./scripts/api-test.sh`
5. To expose it through Bijira, create an API proxy with the Devant endpoint as its backend, as in
   POC 1 and POC 5. Then call it with an OAuth token from the POC 4 client.

The Devant service needs a database it can reach. For a cloud demo before Provident's database
is ready, use any internet-reachable SQL Server test instance (for example Azure SQL with
Devant's outbound IPs allow-listed), and run `db/init.sql` on it.

## 4. Connecting to Provident's database

| Item | What's needed |
|---|---|
| Network | Devant must reach the database. **Public endpoint:** allow-list Devant's outbound IPs for Provident's data plane (WSO2 provides them). **Private or on-premises:** private connectivity (VNet peering, Private Link or VPN) to the dedicated data plane, set up with the WSO2 platform team. |
| Authentication | A **SQL authentication** login. Windows/Kerberos authentication isn't practical from Devant. Azure AD needs extra setup. |
| Permissions | A dedicated login with read/write access to the POC tables only, like `poc_app` in `db/init.sql`. |
| TLS | `dbEncrypt = true`. If the server uses a private CA certificate, it needs adding to a truststore (`cert` in the client options). |
| Schema | Table names and columns. Adjust the SQL in `service.bal` and the records in `types.bal`. |
| Load | Expected request rate. `dbMaxOpenConnections` × number of replicas must stay within the database's connection limit. |

## Notes
- SQL Server's identity values can jump (for example 4 → 1002) after a server restart. This is
  normal SQL Server behaviour, not data loss.
- Deleting a customer keeps its `audit_log` rows (there's no foreign key), so the history
  remains.
