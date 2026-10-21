# POC 9 — Integration 2 with an in-memory database and a mock email service

Builds on POC 8 (Integration 1 in Project1 calling Integration 2 in Project2). Integration 2 now:
- stores **customers in an in-memory SQL database** (H2), created and seeded at startup;
- sends a **welcome email** for each new customer, rendered from an **HTML template with
  placeholders**, through a **mock email service** (an in-memory outbox you can inspect).

Integration 1 passes the customer and email requests through to Integration 2, so everything can
be used from outside Devant while Integration 2 stays Organization-only.

```
Client ──▶ Project1: Integration 1 (Public)
               │  GET /hello, POST /customers, GET /customers…, GET /emails…
               │  API key, through the Devant internal gateway
               ▼
           Project2: Integration 2 (Organization)
               ├── H2 in-memory database: customers
               ├── templates: welcome email with {{placeholders}}
               └── mock email service: outbox (or real SMTP with EMAIL_MODE=smtp)
```

```
09-devant-db-email/
├── project1/integration1/
│   ├── service.bal          /hello, plus pass-through of /customers and /emails to Integration 2
│   └── openapi.yaml
└── project2/integration2/
    ├── service.bal          REST resources
    ├── db.bal               database: H2 (default) or SQL Server, table setup, queries
    ├── db/mssql-schema.sql  SQL Server table script, for the DBA
    ├── templates.bal        built-in template and {{placeholder}} rendering
    ├── templates/welcome-email.html   the same template as a file, to customise and mount
    ├── email.bal            mock outbox and optional SMTP delivery
    ├── config.bal           settings (environment variables)
    ├── types.bal
    └── openapi.yaml
```

## API
The same resources are available on both integrations. On Integration 1 they're passed through
to Integration 2.

| Method & path | What it does | Responses |
|---|---|---|
| `GET /hello?name=…` *(Integration 1)* / `GET /greeting?name=…` *(Integration 2)* | Greeting, as in POC 8 | `200` |
| `POST /customers` `{"name","email"}` | Saves the customer, then sends the welcome email | `201` + `Location`, `400` invalid input, `409` email already registered |
| `GET /customers?limit=20&offset=0` | Lists customers (limit 1–100) | `200`, `400` |
| `GET /customers/{id}` | One customer | `200`, `404` |
| `GET /emails` | The mock outbox, newest first (last 100 emails) | `200` |
| `GET /emails/{id}` | One email: recipient, subject, rendered HTML, status, unresolved placeholders | `200`, `404` |
| `GET /emails/{id}/preview` | The rendered email as an HTML page, viewable in a browser | `200`, `404` |

`POST /customers` response:
```json
{"customer":{"id":3, "name":"Grace Hopper", "email":"grace@example.com", "createdAt":"2026-10-20T12:41:50.939Z"},
 "email":{"id":"10036c0c-…", "status":"SENT", "mode":"mock", "error":null}}
```
Email addresses are stored in lower case, so `Grace@Example.com` and `grace@example.com` count as
the same customer. If the email can't be sent (SMTP mode only), the customer is still saved and
the response shows `"status":"FAILED"` with the reason.

## The database
Integration 2 supports two databases, selected with `DB_TYPE`. The code is the same for both;
only settings change.

| | `DB_TYPE=h2` (default) | `DB_TYPE=mssql` |
|---|---|---|
| What | In-memory H2, inside Integration 2 | Microsoft SQL Server |
| Data | **Resets on every restart or redeploy**; each replica has its own copy | Kept in the database |
| Table | Created at startup, with two sample customers | Created beforehand with `db/mssql-schema.sql` |
| Settings | None needed | `DB_URL`, `DB_USER`, `DB_PASSWORD` |

- Both JDBC drivers are declared in `Ballerina.toml` and downloaded at build time.
- Table `customers`: `id` (generated), `name`, `email` (unique), `created_at`. On SQL Server,
  `name` and `email` are `NVARCHAR`, so names with accents (`José Núñez`) are stored correctly.
- Queries use parameters only. They're standard SQL (`OFFSET … FETCH` for paging) that both
  databases accept.
- A rejected insert (duplicate email) still uses up an ID, so IDs can skip numbers. That's normal.
- With H2, keep Integration 2 at **one replica** for the demo.

### Using SQL Server
1. **Create the table** once with `db/mssql-schema.sql` (for example with `sqlcmd`). The script
   also shows how to create a login that can only read and write data, as in POC 6.
2. **Set Integration 2's settings** in Configs & Secrets:

   | Name | Example |
   |---|---|
   | `DB_TYPE` | `mssql` |
   | `DB_URL` | `jdbc:sqlserver://<host>:1433;databaseName=<db>;encrypt=true` |
   | `DB_USER` | the read/write login, e.g. `poc9_app` |
   | `DB_PASSWORD` | its password (**Secret**) |

   Keep `encrypt=true`. Add `trustServerCertificate=true` only for a test server with a
   self-signed certificate.
3. **Network:** Devant must be able to reach the database: allow-list Devant's outgoing IP
   addresses for a public endpoint, or use private connectivity to the data plane, as in POC 6.
4. **Redeploy** Integration 2. The startup log shows
   `database ready type="mssql" url="jdbc:sqlserver://<host>:1433" setup=false customers=<n>`.
   Only the host and port are logged, never the database options or the password.

`DB_SETUP=true` makes Integration 2 create the table at startup instead (and add the two sample
customers if the table is empty). That needs a login allowed to create tables, so it's meant for
test databases. With a read/write-only login, startup stops with `CREATE TABLE permission denied`.

Tested locally against SQL Server 2022 (Docker): script-created table with a read/write-only
login, `DB_SETUP=true` with an admin login (and again on restart, without duplicating the sample
rows), the read/write-only login being refused `CREATE TABLE`, data kept across restarts,
duplicates rejected regardless of letter case, accented names, wrong password and unreachable
server (clear startup errors, password not logged), and the full flow through Integration 1.

## The email template
The welcome email is HTML with these placeholders:

| Placeholder | Value |
|---|---|
| `{{customerName}}` | Customer's name |
| `{{customerId}}` | Customer ID |
| `{{customerEmail}}` | Customer's email address |
| `{{registeredAt}}` | Registration time (UTC) |
| `{{companyName}}` | `COMPANY_NAME` setting (default `Provident Bank`) |
| `{{supportEmail}}` | `SUPPORT_EMAIL` setting (default `support@example.com`) |

Subject: `Welcome to {{companyName}}, {{customerName}}!`

- Values are HTML-escaped in the body, so a name like `<Bob & Co>` displays as typed.
- A placeholder with no value is left as-is, logged as a warning, and listed in the email's
  `unresolvedPlaceholders`.
- **Changing the template without a code change:** copy `templates/welcome-email.html`, edit it,
  mount it in Devant (Integration 2 → Configs & Secrets → file mount), and set
  `EMAIL_TEMPLATE_FILE` to the mount path. The subject can be changed with
  `EMAIL_SUBJECT_TEMPLATE`. The startup log shows which template was loaded.
- The built-in template in `templates.bal` has the same content as `templates/welcome-email.html`.
  If you change one, change the other.

## The mock email service
- `EMAIL_MODE=mock` (default): emails are rendered and kept in an in-memory outbox (last 100). No
  email leaves the integration. View them with `GET /emails` and `GET /emails/{id}/preview`.
- The log records each email's ID, template and a masked recipient (`g***@example.com`), never the
  address or content.
- `EMAIL_MODE=smtp`: the same emails are sent through an SMTP server and also recorded in the
  outbox. Tested against a local SMTP server.
- **Before production:** `GET /emails` and its sub-resources expose customers' email addresses and
  the email content. They're there for the demo; remove or restrict them before go-live.

## Settings
Both integrations read environment variables, set in Devant under **Configs & Secrets**
(Mount: Environment Variables). Redeploy after changing them.

**Integration 1** (unchanged from POC 8):

| Name | Value |
|---|---|
| `INTEGRATION2_URL` | Connection → `ServiceURL` (required) |
| `CHOREO_API_KEY` | Connection → `ChoreoAPIKey` (Secret) |
| `INTEGRATION2_VERIFY_TLS` | `false` while the internal gateway certificate issue is open (PROVIDENTBIJIRAANDDEVANT-37) |
| `INTEGRATION2_TIMEOUT_SECONDS` | Optional, default 30 |

**Integration 2** (all optional; the defaults run the POC):

| Name | Default | Purpose |
|---|---|---|
| `COMPANY_NAME` | `Provident Bank` | `{{companyName}}` |
| `SUPPORT_EMAIL` | `support@example.com` | `{{supportEmail}}` |
| `EMAIL_FROM` | `no-reply@example.com` | Sender address |
| `EMAIL_SUBJECT_TEMPLATE` | `Welcome to {{companyName}}, {{customerName}}!` | Subject |
| `EMAIL_TEMPLATE_FILE` | *(built-in)* | Path to a mounted HTML template |
| `EMAIL_MODE` | `mock` | `mock` or `smtp` |
| `SMTP_HOST`, `SMTP_PORT` (587), `SMTP_USERNAME`, `SMTP_PASSWORD` (Secret), `SMTP_SECURITY` (`START_TLS_AUTO`) | — | Only for `EMAIL_MODE=smtp`. `SMTP_SECURITY`: `START_TLS_AUTO`, `START_TLS_ALWAYS`, `START_TLS_NEVER` or `SSL`. |
| `DB_TYPE` | `h2` | `h2` (in-memory) or `mssql` (SQL Server) |
| `DB_URL`, `DB_USER`, `DB_PASSWORD` (Secret) | H2 in-memory | Required for `mssql`; see [Using SQL Server](#using-sql-server) |
| `DB_SETUP` | `true` for h2, `false` for mssql | Create the table (and sample customers) at startup |

Invalid settings stop the integration at startup with a clear message (for example
`EMAIL_MODE must be 'mock' or 'smtp'`, `DB_URL is required when DB_TYPE is 'mssql'`, or a
template file that can't be read).

Integration 2's startup log:
```
email template loaded    template="welcome-email" source="built-in"
customers table created  type="h2"
database ready           type="h2" url="jdbc:h2:mem:pocdb" setup=true customers=2
email service ready      mode="mock" from="no-reply@example.com"
```

## Deploy to Devant
Same as POC 8, from branches `poc09-project1` and `poc09-project2`:
1. **Integration 2** (Project2, Integration as API, directory `project2/integration2`): Build,
   Deploy. Optionally set the Integration 2 settings above first. Check that its endpoint is
   **Organization** and lists the resources above.
2. **Integration 1** (Project1, Integration as API, directory `project1/integration1`): Build.
3. **Connection** from Integration 1 to Integration 2, and Integration 1's Configs & Secrets as in
   POC 8. If you're reusing the POC 8 components, rebuild them from the new branches; the
   Connection and settings stay the same.
4. **Deploy** Integration 1.
5. **Try it** through Integration 1 (`…/project1/integration1/v1.0`):
   ```bash
   curl -X POST "<invoke URL>/customers" -H "Authorization: Bearer <token>" \
        -H "Content-Type: application/json" -d '{"name":"Grace Hopper","email":"grace@example.com"}'
   curl "<invoke URL>/emails" -H "Authorization: Bearer <token>"
   ```
   Open `<invoke URL>/emails/<email id>/preview` in the Test console or a browser (with the
   token) to see the rendered email.

## Run locally
Ballerina 2201.12.8 or later, Java 21.

```bash
(cd project2/integration2 && bal run -- -Cport=9092)
(cd project1/integration1 && INTEGRATION2_URL=http://localhost:9092 bal run)

curl -X POST localhost:9090/customers -H 'Content-Type: application/json' \
     -d '{"name":"Grace Hopper","email":"grace@example.com"}'
curl localhost:9090/emails
open "http://localhost:9090/emails/<email id>/preview"
```
