import ballerina/http;
import ballerina/lang.regexp;
import ballerina/log;
import ballerina/sql;
import ballerina/time;

// Integration 2 (Project2): customer registration backed by an in-memory
// database, with a welcome email rendered from a template and sent through
// the mock email service. Also keeps the original greeting resource.
// Endpoint visibility is Organization, so integrations in other projects of
// the same organization can call it through the Devant gateway.

configurable int port = 9090;

final regexp:RegExp emailPattern = re `^[^@\s]+@[^@\s]+\.[^@\s]+$`;

service / on new http:Listener(port) {

    // GET /greeting?name=Provident
    resource function get greeting(string name = "World") returns json {
        log:printInfo("greeting request received", name = name);
        return {
            message: string `Hello, ${name}!`,
            servedBy: "integration2",
            project: "Project2",
            timestamp: time:utcToString(time:utcNow())
        };
    }

    // POST /customers {"name": "...", "email": "..."}
    // Saves the customer, then sends the welcome email.
    resource function post customers(NewCustomer body)
            returns http:Created|http:BadRequest|http:Conflict|error {
        string name = body.name.trim();
        string emailAddress = body.email.trim().toLowerAscii();
        if name == "" || name.length() > 100 {
            return <http:BadRequest>{body: <ErrorBody>{message: "name is required (up to 100 characters)"}};
        }
        if !emailPattern.isFullMatch(emailAddress) || emailAddress.length() > 255 {
            return <http:BadRequest>{body: <ErrorBody>{message: "email must be a valid email address"}};
        }

        Customer|DuplicateEmail|error saved = insertCustomer({name, email: emailAddress});
        if saved is DuplicateEmail {
            return <http:Conflict>{body: <ErrorBody>{message: saved.message()}};
        }
        Customer customer = check saved;
        log:printInfo("customer created", customerId = customer.id);

        EmailMessage sent = sendWelcomeEmail(customer);
        CustomerCreated created = {
            customer,
            email: {id: sent.id, status: sent.status, mode: sent.mode, 'error: sent.'error}
        };
        return <http:Created>{headers: {"Location": string `/customers/${customer.id}`}, body: created};
    }

    // GET /customers?limit=20&offset=0
    resource function get customers(int 'limit = 20, int offset = 0) returns Customer[]|http:BadRequest|error {
        if 'limit < 1 || 'limit > 100 || offset < 0 {
            return <http:BadRequest>{body: <ErrorBody>{message: "limit must be 1-100 and offset 0 or more"}};
        }
        return listCustomers('limit, offset);
    }

    // GET /customers/{id}
    resource function get customers/[int id]() returns Customer|http:NotFound|error {
        Customer|sql:NoRowsError|error customer = findCustomer(id);
        if customer is sql:NoRowsError {
            return <http:NotFound>{body: <ErrorBody>{message: string `customer ${id} not found`}};
        }
        return customer;
    }

    // GET /emails: the mock outbox, newest first
    resource function get emails() returns EmailMessage[] => listEmails();

    // GET /emails/{id}
    resource function get emails/[string id]() returns EmailMessage|http:NotFound {
        EmailMessage? message = findEmail(id);
        return message ?: <http:NotFound>{body: <ErrorBody>{message: string `email ${id} not found`}};
    }

    // GET /emails/{id}/preview: the rendered email as an HTML page
    resource function get emails/[string id]/preview() returns http:Response|http:NotFound {
        EmailMessage? message = findEmail(id);
        if message is () {
            return <http:NotFound>{body: <ErrorBody>{message: string `email ${id} not found`}};
        }
        http:Response response = new;
        response.setTextPayload(message.htmlBody, "text/html; charset=utf-8");
        return response;
    }
}
