import ballerina/log;
import ballerina/sql;
import ballerina/time;
import ballerinax/java.jdbc;

// The customers database. DB_TYPE selects it:
//   h2     in-memory H2 (default). The table and two sample customers are
//          created at startup, so the data resets whenever Integration 2 restarts.
//   mssql  Microsoft SQL Server. The table is normally created beforehand with
//          db/mssql-schema.sql; DB_SETUP=true creates it at startup instead.
// Both drivers are bundled (Ballerina.toml). The queries below use standard SQL
// that both databases accept; only the table definition and the duplicate-key
// error codes differ.

final jdbc:Client db = check initDb();

function initDb() returns jdbc:Client|error {
    if dbType != H2 && dbType != MSSQL {
        return error(string `DB_TYPE must be 'h2' or 'mssql', found '${dbType}'`);
    }
    if dbUrl == "" {
        return error(string `DB_URL is required when DB_TYPE is '${dbType}'`);
    }
    // SQL Server's driver only returns generated IDs for single statements (EXECUTE).
    jdbc:Options options = dbType == MSSQL ? {requestGeneratedKeys: jdbc:EXECUTE} : {};
    jdbc:Client jdbcClient = check new (dbUrl, dbUser, dbPassword, options);
    if dbSetup {
        check createTableIfMissing(jdbcClient);
        int existing = check jdbcClient->queryRow(`SELECT COUNT(*) FROM customers`);
        if existing == 0 {
            string now = time:utcToString(time:utcNow());
            _ = check jdbcClient->execute(`INSERT INTO customers (name, email, created_at)
                    VALUES ('Ada Lovelace', 'ada@example.com', ${now}), ('Alan Turing', 'alan@example.com', ${now})`);
        }
    }
    int total = check jdbcClient->queryRow(`SELECT COUNT(*) FROM customers`);
    log:printInfo("database ready", 'type = dbType, url = redactUrl(dbUrl), setup = dbSetup, customers = total);
    return jdbcClient;
}

// Creates the customers table if it doesn't exist yet.
function createTableIfMissing(jdbc:Client jdbcClient) returns error? {
    int tables = check jdbcClient->queryRow(`SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES
            WHERE UPPER(TABLE_NAME) = 'CUSTOMERS'`);
    if tables == 0 {
        _ = check jdbcClient->execute(dbType == H2 ? H2_CREATE_TABLE : MSSQL_CREATE_TABLE);
        log:printInfo("customers table created", 'type = dbType);
    }
}

final sql:ParameterizedQuery H2_CREATE_TABLE = `
    CREATE TABLE customers (
        id         INT AUTO_INCREMENT PRIMARY KEY,
        name       VARCHAR(100) NOT NULL,
        email      VARCHAR(255) NOT NULL UNIQUE,
        created_at VARCHAR(40)  NOT NULL
    )`;

// Same definition as db/mssql-schema.sql.
final sql:ParameterizedQuery MSSQL_CREATE_TABLE = `
    CREATE TABLE dbo.customers (
        id         INT IDENTITY(1,1) PRIMARY KEY,
        name       NVARCHAR(100) NOT NULL,
        email      NVARCHAR(255) NOT NULL CONSTRAINT uq_customers_email UNIQUE,
        created_at VARCHAR(40)   NOT NULL
    )`;

function insertCustomer(NewCustomer c) returns Customer|DuplicateEmail|error {
    string now = time:utcToString(time:utcNow());
    sql:ExecutionResult|sql:Error result = db->execute(`INSERT INTO customers (name, email, created_at)
            VALUES (${c.name}, ${c.email}, ${now})`);
    if result is sql:DatabaseError && isUniqueViolation(result) {
        return error DuplicateEmail("a customer with this email already exists");
    }
    sql:ExecutionResult inserted = check result;
    // H2 returns the generated ID as an int; SQL Server's driver can return it as a string.
    string|int? key = inserted.lastInsertId;
    if key is () {
        return error("the database didn't return the new customer's ID");
    }
    int id = key is int ? key : check int:fromString(key);
    return {id, name: c.name, email: c.email, createdAt: now};
}

function findCustomer(int id) returns Customer|sql:NoRowsError|error {
    return db->queryRow(`SELECT id, name, email, created_at AS createdAt FROM customers WHERE id = ${id}`);
}

// OFFSET ... FETCH is standard SQL, accepted by both H2 and SQL Server.
function listCustomers(int 'limit, int offset) returns Customer[]|error {
    stream<Customer, sql:Error?> rows = db->query(`SELECT id, name, email, created_at AS createdAt
            FROM customers ORDER BY id OFFSET ${offset} ROWS FETCH NEXT ${'limit} ROWS ONLY`);
    return from Customer c in rows select c;
}

type DuplicateEmail distinct error;

// Unique constraint violation: SQLSTATE 23505 (H2), error 2627 or 2601 (SQL Server).
function isUniqueViolation(sql:DatabaseError e) returns boolean {
    int code = e.detail().errorCode;
    return e.detail().sqlState == "23505" || code == 23505 || code == 2627 || code == 2601;
}

// Logs the database type, host and port only, never credentials or options.
function redactUrl(string url) returns string {
    int? semicolon = url.indexOf(";");
    int? query = url.indexOf("?");
    int end = semicolon ?: query ?: url.length();
    return url.substring(0, end);
}
