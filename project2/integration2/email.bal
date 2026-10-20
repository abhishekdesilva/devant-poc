import ballerina/email;
import ballerina/log;
import ballerina/os;
import ballerina/time;
import ballerina/uuid;

// Email delivery. EMAIL_MODE=mock (default) keeps every email in an in-memory
// outbox, viewable through GET /emails, and sends nothing. EMAIL_MODE=smtp
// sends through a real SMTP server; the outbox still records what was sent.

const int OUTBOX_LIMIT = 100;   // oldest emails are dropped beyond this

// Oldest first. Entries are read-only, so they can be handed out safely.
isolated (EmailMessage & readonly)[] outbox = [];

final email:SmtpClient? smtpClient = check initSmtp();

function initSmtp() returns email:SmtpClient?|error {
    if emailMode == "mock" {
        log:printInfo("email service ready", mode = "mock", 'from = emailFrom);
        return ();
    }
    if emailMode != "smtp" {
        return error(string `EMAIL_MODE must be 'mock' or 'smtp', found '${emailMode}'`);
    }
    string host = os:getEnv("SMTP_HOST").trim();
    if host == "" {
        return error("EMAIL_MODE is 'smtp' but SMTP_HOST is not set");
    }
    int port = check int:fromString(setting("SMTP_PORT", "587"));
    string security = setting("SMTP_SECURITY", "START_TLS_AUTO");
    email:Security mode = check security.cloneWithType();
    email:SmtpClient smtp = check new (host, os:getEnv("SMTP_USERNAME"), os:getEnv("SMTP_PASSWORD"),
        {port, security: mode});
    log:printInfo("email service ready", mode = "smtp", host = host, port = port, security = security,
            'from = emailFrom);
    return smtp;
}

// Renders the welcome template for a customer and delivers it.
function sendWelcomeEmail(Customer c) returns EmailMessage {
    readonly & map<string> values = {
        customerName: c.name,
        customerId: c.id.toString(),
        customerEmail: c.email,
        registeredAt: c.createdAt,
        companyName,
        supportEmail
    };
    [string, string[]] [subject, subjectMissing] = render(subjectTemplate, values, false);
    [string, string[]] [body, bodyMissing] = render(htmlTemplate, values, true);
    string[] unresolved = subjectMissing;
    foreach string name in bodyMissing {
        if unresolved.indexOf(name) is () {
            unresolved.push(name);
        }
    }
    if unresolved.length() > 0 {
        log:printWarn("template has placeholders with no value", placeholders = unresolved);
    }

    EmailMessage message = {
        id: uuid:createType4AsString(),
        to: c.email,
        subject,
        htmlBody: body,
        template: WELCOME_TEMPLATE_NAME,
        mode: emailMode,
        status: "SENT",
        sentAt: time:utcToString(time:utcNow()),
        unresolvedPlaceholders: unresolved
    };

    email:SmtpClient? smtp = smtpClient;
    if smtp is email:SmtpClient {
        email:Error? sent = smtp->sendMessage({to: c.email, 'from: emailFrom, subject, htmlBody: body});
        if sent is email:Error {
            message.status = "FAILED";
            message.'error = sent.message();
        }
    }
    recordEmail(message.cloneReadOnly());
    // Logs the email ID and a masked recipient, not the address or content.
    log:printInfo("email " + (message.status == "SENT" ? "sent" : "failed"), emailId = message.id,
            mode = emailMode, template = WELCOME_TEMPLATE_NAME, to = mask(c.email), status = message.status);
    return message;
}

isolated function recordEmail(EmailMessage & readonly message) {
    lock {
        outbox.push(message);
        while outbox.length() > OUTBOX_LIMIT {
            _ = outbox.shift();
        }
    }
}

isolated function listEmails() returns EmailMessage[] {
    lock {
        // Newest first.
        return outbox.reverse().clone();
    }
}

isolated function findEmail(string id) returns EmailMessage? {
    lock {
        foreach EmailMessage & readonly message in outbox {
            if message.id == id {
                return message;
            }
        }
        return ();
    }
}

// a***@example.com
isolated function mask(string address) returns string {
    int? at = address.indexOf("@");
    return at is () || at < 1 ? "***" : address.substring(0, 1) + "***" + address.substring(at);
}
