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
    ├── db.bal               H2 in-memory database: schema, seed data, queries
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

## The in-memory database
- H2, running inside Integration 2 (`jdbc:h2:mem:pocdb`). The driver is declared in
  `Ballerina.toml` and downloaded at build time.
- Table `customers` (`id`, `name`, `email` unique, `created_at`), with two seed customers.
- **Data resets whenever Integration 2 restarts or is redeployed**, and each replica has its own
  copy. Keep Integration 2 at one replica for the demo.
- Queries use parameters only, through Ballerina's JDBC client. To use a real database later, set
  `DB_URL`, `DB_USER` and `DB_PASSWORD`, and add that database's JDBC driver to `Ballerina.toml`.
- A rejected insert (duplicate email) still uses up an ID, so IDs can skip numbers. That's normal.

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
| `DB_URL`, `DB_USER`, `DB_PASSWORD` | H2 in-memory | Only to use a different database |

Invalid settings stop the integration at startup with a clear message (for example
`EMAIL_MODE must be 'mock' or 'smtp'`, or a template file that can't be read).

Integration 2's startup log:
```
email template loaded  template="welcome-email" source="built-in"
database ready         url="jdbc:h2:mem:pocdb" customers=2
email service ready    mode="mock" from="no-reply@example.com"
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
