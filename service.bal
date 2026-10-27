import ballerina/http;
import ballerina/log;
import ballerina/sql;
import ballerinax/mssql;
import ballerinax/mssql.driver as _;

// ---------------------------------------------------------------------------
// POC 6: Read/write operations on Microsoft SQL Server from a Devant-hosted
// integration, exposed as a REST API (put Bijira in front for OAuth).
//
// Every connection setting is a configurable, so pointing this at the
// customer's database is a Devant configuration change only:
// Devant -> component -> Configs & Secrets (dbPassword as a secret).
//
// Writes run in a transaction together with an audit_log insert, so a
// customer row and its audit entry are committed or rolled back together.
// Logs carry IDs only, never customer data (names/emails are PII).
// ---------------------------------------------------------------------------

configurable string dbHost = "localhost";
configurable int dbPort = 1433;
configurable string dbName = "pocdb";
configurable string dbUser = ?;
configurable string dbPassword = ?;
// Named instance (e.g. SQLEXPRESS); leave empty for the default instance.
configurable string dbInstance = "";
// TLS to the database. Keep encrypt on; only trust an unverified server
// certificate for local/dev databases with self-signed certificates.
configurable boolean dbEncrypt = true;
configurable boolean dbTrustServerCertificate = false;
configurable int dbMaxOpenConnections = 10;
configurable int dbLoginTimeoutSeconds = 15;
configurable int dbQueryTimeoutSeconds = 30;
// How long a request waits for a pooled connection before failing.
configurable int dbConnectionTimeoutSeconds = 10;
configurable int servicePort = 9090;

const int MAX_PAGE_SIZE = 100;
// SQL Server error numbers for unique constraint / unique index violations.
const int UNIQUE_CONSTRAINT_VIOLATION = 2627;
const int UNIQUE_INDEX_VIOLATION = 2601;

final mssql:Client db = check new (
    host = dbHost,
    user = dbUser,
    password = dbPassword,
    database = dbName,
    port = dbPort,
    instance = dbInstance,
    options = {
        secureSocket: {encrypt: dbEncrypt, trustServerCertificate: dbTrustServerCertificate},
        loginTimeout: <decimal>dbLoginTimeoutSeconds,
        queryTimeout: <decimal>dbQueryTimeoutSeconds
    },
    connectionPool = {maxOpenConnections: dbMaxOpenConnections, connectionTimeout: <decimal>dbConnectionTimeoutSeconds}
);

listener http:Listener apiListener = new (servicePort);

service /customers on apiListener {

    // GET /customers?limit=20&offset=0
    resource function get .(int 'limit = 20, int offset = 0) returns Customer[]|http:BadRequest|error {
        if 'limit < 1 || 'limit > MAX_PAGE_SIZE || offset < 0 {
            return badRequest(string `limit must be 1-${MAX_PAGE_SIZE} and offset must be >= 0`);
        }
        stream<Customer, sql:Error?> rows = db->query(`
            SELECT id, name, email, phone,
                   CONVERT(VARCHAR(33), created_at, 127) + 'Z' AS createdAt,
                   CONVERT(VARCHAR(33), updated_at, 127) + 'Z' AS updatedAt
            FROM dbo.customers
            ORDER BY id
            OFFSET ${offset} ROWS FETCH NEXT ${'limit} ROWS ONLY`);
        return from Customer c in rows select c;
    }

    // GET /customers/{id}
    resource function get [int id]() returns Customer|http:NotFound|error {
        Customer|sql:Error customer = selectCustomer(id);
        if customer is sql:NoRowsError {
            return notFound(id);
        }
        return customer;
    }

    // POST /customers
    resource function post .(NewCustomer body) returns http:Created|http:BadRequest|http:Conflict|error {
        string? invalid = validate(body.name, body.email);
        if invalid is string {
            return badRequest(invalid);
        }
        int|sql:Error id;
        transaction {
            id = db->queryRow(`
                INSERT INTO dbo.customers (name, email, phone)
                OUTPUT INSERTED.id
                VALUES (${body.name.trim()}, ${body.email.trim()}, ${body.phone})`);
            if id is int {
                _ = check audit("CREATE", id);
            }
            check commit;
        }
        if id is sql:Error {
            return isDuplicate(id) ? duplicateEmail() : id;
        }
        log:printInfo("customer created", customerId = id);
        http:Created created = {headers: {"Location": string `/customers/${id}`}, body: check selectCustomer(id)};
        return created;
    }

    // PUT /customers/{id}
    resource function put [int id](CustomerUpdate body)
            returns Customer|http:BadRequest|http:NotFound|http:Conflict|error {
        string? invalid = validate(body.name, body.email);
        if invalid is string {
            return badRequest(invalid);
        }
        sql:ExecutionResult|sql:Error result;
        transaction {
            result = db->execute(`
                UPDATE dbo.customers
                SET name = ${body.name.trim()}, email = ${body.email.trim()}, phone = ${body.phone},
                    updated_at = SYSUTCDATETIME()
                WHERE id = ${id}`);
            if result is sql:ExecutionResult && result.affectedRowCount == 1 {
                _ = check audit("UPDATE", id);
            }
            check commit;
        }
        if result is sql:Error {
            return isDuplicate(result) ? duplicateEmail() : result;
        }
        if result.affectedRowCount == 0 {
            return notFound(id);
        }
        log:printInfo("customer updated", customerId = id);
        return selectCustomer(id);
    }

    // DELETE /customers/{id}
    resource function delete [int id]() returns http:NoContent|http:NotFound|error {
        sql:ExecutionResult result;
        transaction {
            result = check db->execute(`DELETE FROM dbo.customers WHERE id = ${id}`);
            if result.affectedRowCount == 1 {
                _ = check audit("DELETE", id);
            }
            check commit;
        }
        if result.affectedRowCount == 0 {
            return notFound(id);
        }
        log:printInfo("customer deleted", customerId = id);
        return http:NO_CONTENT;
    }
}

service /health on apiListener {

    // GET /health - checks the service can reach and query the database.
    resource function get .() returns Health|http:ServiceUnavailable {
        int|sql:Error ping = db->queryRow(`SELECT 1`);
        if ping is sql:Error {
            // Details stay in the logs; callers only learn that the database is unavailable.
            log:printError("database health check failed", ping);
            return {body: {status: "DOWN", database: "UNREACHABLE"}};
        }
        return {status: "UP", database: "UP"};
    }
}

function selectCustomer(int id) returns Customer|sql:Error {
    return db->queryRow(`
        SELECT id, name, email, phone,
               CONVERT(VARCHAR(33), created_at, 127) + 'Z' AS createdAt,
               CONVERT(VARCHAR(33), updated_at, 127) + 'Z' AS updatedAt
        FROM dbo.customers WHERE id = ${id}`);
}

transactional function audit(string action, int customerId) returns sql:ExecutionResult|sql:Error {
    return db->execute(`
        INSERT INTO dbo.audit_log (action, customer_id) VALUES (${action}, ${customerId})`);
}

function validate(string name, string email) returns string? {
    if name.trim() == "" {
        return "name is required";
    }
    if !email.includes("@") {
        return "email must be a valid email address";
    }
    return ();
}

function isDuplicate(sql:Error err) returns boolean {
    if err is sql:DatabaseError {
        int code = err.detail().errorCode;
        return code == UNIQUE_CONSTRAINT_VIOLATION || code == UNIQUE_INDEX_VIOLATION;
    }
    return false;
}

function badRequest(string message) returns http:BadRequest => {body: <ErrorBody>{message}};

function notFound(int id) returns http:NotFound => {body: <ErrorBody>{message: string `customer ${id} not found`}};

function duplicateEmail() returns http:Conflict => {body: <ErrorBody>{message: "a customer with this email already exists"}};
