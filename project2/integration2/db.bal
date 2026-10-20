import ballerina/log;
import ballerina/sql;
import ballerina/time;
import ballerinax/java.jdbc;

// In-memory H2 database. The schema and two seed customers are created at
// startup, so the data resets whenever Integration 2 restarts. Pointing DB_URL
// at another database (with its JDBC driver added to Ballerina.toml) needs no
// other code change for these queries.

final jdbc:Client db = check initDb();

function initDb() returns jdbc:Client|error {
    jdbc:Client jdbcClient = check new (dbUrl, dbUser, dbPassword);
    _ = check jdbcClient->execute(`
        CREATE TABLE IF NOT EXISTS customers (
            id         INT AUTO_INCREMENT PRIMARY KEY,
            name       VARCHAR(100) NOT NULL,
            email      VARCHAR(255) NOT NULL UNIQUE,
            created_at VARCHAR(40)  NOT NULL
        )`);
    int existing = check jdbcClient->queryRow(`SELECT COUNT(*) FROM customers`);
    if existing == 0 {
        string now = time:utcToString(time:utcNow());
        _ = check jdbcClient->execute(`INSERT INTO customers (name, email, created_at)
                VALUES ('Ada Lovelace', 'ada@example.com', ${now}), ('Alan Turing', 'alan@example.com', ${now})`);
    }
    int total = check jdbcClient->queryRow(`SELECT COUNT(*) FROM customers`);
    log:printInfo("database ready", url = redactUrl(dbUrl), customers = total);
    return jdbcClient;
}

function insertCustomer(NewCustomer c) returns Customer|DuplicateEmail|error {
    string now = time:utcToString(time:utcNow());
    sql:ExecutionResult|sql:Error result = db->execute(`INSERT INTO customers (name, email, created_at)
            VALUES (${c.name}, ${c.email}, ${now})`);
    if result is sql:DatabaseError && isUniqueViolation(result) {
        return error DuplicateEmail("a customer with this email already exists");
    }
    sql:ExecutionResult inserted = check result;
    int id = check inserted.lastInsertId.ensureType(int);
    return {id, name: c.name, email: c.email, createdAt: now};
}

function findCustomer(int id) returns Customer|sql:NoRowsError|error {
    return db->queryRow(`SELECT id, name, email, created_at AS createdAt FROM customers WHERE id = ${id}`);
}

function listCustomers(int 'limit, int offset) returns Customer[]|error {
    stream<Customer, sql:Error?> rows = db->query(`SELECT id, name, email, created_at AS createdAt
            FROM customers ORDER BY id LIMIT ${'limit} OFFSET ${offset}`);
    return from Customer c in rows select c;
}

type DuplicateEmail distinct error;

// 23505 is the standard SQLSTATE for a unique constraint violation.
function isUniqueViolation(sql:DatabaseError e) returns boolean =>
    e.detail().sqlState == "23505" || e.detail().errorCode == 23505;

// Logs the database type and name only, never credentials.
function redactUrl(string url) returns string {
    int? semicolon = url.indexOf(";");
    int? query = url.indexOf("?");
    int end = semicolon ?: query ?: url.length();
    return url.substring(0, end);
}
