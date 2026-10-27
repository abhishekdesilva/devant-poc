import ballerina/lang.regexp;
import ballerina/log;

// ---------------------------------------------------------------------------
// POC 3: Mask PII in application logs.
//
// This is the log-masking counterpart to an AI Gateway PII-masking
// guardrail — that masks PII in LLM prompts/responses at the gateway; this
// masks PII in your own service's log lines before they ever reach stdout /
// a log aggregator, so raw emails, phone numbers, card numbers, etc. never
// land in observability tooling.
//
// Approach: a set of regexes for common PII shapes, applied to every log
// message through a thin wrapper around ballerina/log. Structured fields
// (email, ssn, etc. passed alongside the message) are masked by field name
// instead of pattern-matching the value, which is more reliable.
// ---------------------------------------------------------------------------

final regexp:RegExp EMAIL_PATTERN = re `[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}`;
final regexp:RegExp CREDIT_CARD_PATTERN = re `(?:\d[ -]*?){13,16}`;
final regexp:RegExp SSN_PATTERN = re `\d{3}-\d{2}-\d{4}`;
final regexp:RegExp PHONE_PATTERN = re `(?:\+?\d{1,3}[- ]?)?\(?\d{3}\)?[- ]?\d{3}[- ]?\d{4}`;

// Field names that should always be fully masked, regardless of content.
final string[] SENSITIVE_FIELD_NAMES = ["email", "ssn", "creditcard", "phone", "password", "apikey"];

# Masks known PII shapes (email, credit card, SSN, phone) inside a free-text
# log message.
#
# + message - the raw log message that may contain PII
# + return - the same message with PII substrings replaced by a redaction marker
function maskPii(string message) returns string {
    string masked = message;
    masked = EMAIL_PATTERN.replaceAll(masked, "***@***.***");
    masked = SSN_PATTERN.replaceAll(masked, "***-**-****");
    masked = CREDIT_CARD_PATTERN.replaceAll(masked, "**** **** **** ****");
    masked = PHONE_PATTERN.replaceAll(masked, "***-***-****");
    return masked;
}

# Drop-in replacement for `log:printInfo` that masks the free-text message
# and redacts any structured field whose name looks sensitive, e.g.
# `logInfo("booking created", {email: user.email, userId: user.id})` logs
# `email` as `***REDACTED***` but leaves `userId` untouched.
#
# + message - free-text log message
# + fields - structured fields to attach to the log line
public function logInfo(string message, map<anydata> fields = {}) {
    log:printInfo(formatLogLine(message, fields));
}

# Drop-in replacement for `log:printError` with the same masking behavior.
#
# + message - free-text log message
# + cause - the underlying error, if any
# + fields - structured fields to attach to the log line
public function logError(string message, error? cause = (), map<anydata> fields = {}) {
    log:printError(formatLogLine(message, fields), 'error = cause);
}

function formatLogLine(string message, map<anydata> fields) returns string {
    string masked = maskPii(message);
    if fields.length() == 0 {
        return masked;
    }

    string[] parts = [];
    foreach [string, anydata] [key, value] in fields.entries() {
        parts.push(key + "=" + maskFieldValue(key, value));
    }
    return masked + " {" + string:'join(", ", ...parts) + "}";
}

function maskFieldValue(string key, anydata value) returns string {
    boolean isSensitive = SENSITIVE_FIELD_NAMES.some(name => key.toLowerAscii().includes(name));
    if isSensitive {
        return "***REDACTED***";
    }
    if value is string {
        return maskPii(value);
    }
    return value.toString();
}
