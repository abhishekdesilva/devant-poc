import ballerina/io;
import ballerina/lang.regexp;
import ballerina/log;
import ballerina/os;

// Email templates use {{placeholder}} markers. Available placeholders:
//   {{customerName}}  {{customerId}}  {{customerEmail}}  {{registeredAt}}
//   {{companyName}}   {{supportEmail}}
// Values are HTML-escaped in the body. A marker with no value is left as-is
// and reported in the email's unresolvedPlaceholders.

const string WELCOME_TEMPLATE_NAME = "welcome-email";

const string DEFAULT_SUBJECT_TEMPLATE = "Welcome to {{companyName}}, {{customerName}}!";

// Same content as templates/welcome-email.html. To change the template without
// rebuilding, mount an HTML file in Devant and set EMAIL_TEMPLATE_FILE to its path.
final string DEFAULT_HTML_TEMPLATE = string `<!DOCTYPE html>
<html>
<body style="margin:0;padding:24px;background:#f4f6f8;font-family:Arial,Helvetica,sans-serif;color:#1f2933;">
  <table role="presentation" width="100%" style="max-width:560px;margin:0 auto;background:#ffffff;border-radius:8px;">
    <tr>
      <td style="padding:24px 32px;background:#1f3864;color:#ffffff;border-radius:8px 8px 0 0;">
        <h1 style="margin:0;font-size:20px;">{{companyName}}</h1>
      </td>
    </tr>
    <tr>
      <td style="padding:32px;">
        <p style="margin:0 0 16px;">Dear {{customerName}},</p>
        <p style="margin:0 0 16px;">Welcome to {{companyName}}. Your registration is complete.</p>
        <table role="presentation" style="margin:0 0 16px;border-collapse:collapse;">
          <tr><td style="padding:4px 16px 4px 0;color:#52606d;">Customer ID</td><td style="padding:4px 0;"><strong>{{customerId}}</strong></td></tr>
          <tr><td style="padding:4px 16px 4px 0;color:#52606d;">Email</td><td style="padding:4px 0;">{{customerEmail}}</td></tr>
          <tr><td style="padding:4px 16px 4px 0;color:#52606d;">Registered on</td><td style="padding:4px 0;">{{registeredAt}}</td></tr>
        </table>
        <p style="margin:0 0 16px;">If you have any questions, contact us at {{supportEmail}}.</p>
        <p style="margin:0;">Kind regards,<br>The {{companyName}} team</p>
      </td>
    </tr>
  </table>
</body>
</html>
`;

final string subjectTemplate = setting("EMAIL_SUBJECT_TEMPLATE", DEFAULT_SUBJECT_TEMPLATE);
final string htmlTemplate = check loadHtmlTemplate();

function loadHtmlTemplate() returns string|error {
    string path = os:getEnv("EMAIL_TEMPLATE_FILE").trim();
    if path == "" {
        log:printInfo("email template loaded", template = WELCOME_TEMPLATE_NAME, 'source = "built-in");
        return DEFAULT_HTML_TEMPLATE;
    }
    string|io:Error content = io:fileReadString(path);
    if content is io:Error {
        return error(string `EMAIL_TEMPLATE_FILE '${path}' can't be read: ${content.message()}`);
    }
    log:printInfo("email template loaded", template = WELCOME_TEMPLATE_NAME, 'source = path);
    return content;
}

final regexp:RegExp placeholder = re `\{\{\s*([A-Za-z0-9_]+)\s*\}\}`;

// Fills the {{placeholders}} in a template. Returns the result and the names
// of placeholders that had no value.
isolated function render(string template, readonly & map<string> values, boolean escapeHtml)
        returns [string, string[]] {
    string[] unresolved = [];
    foreach regexp:Groups groups in placeholder.findAllGroups(template) {
        string name = nameOf(groups);
        if !values.hasKey(name) && unresolved.indexOf(name) is () {
            unresolved.push(name);
        }
    }
    string result = placeholder.replaceAll(template, isolated function(regexp:Groups groups) returns string {
        string name = nameOf(groups);
        string? value = values[name];
        if value is () {
            return groups[0].substring();
        }
        return escapeHtml ? htmlEscape(value) : value;
    });
    return [result, unresolved];
}

isolated function nameOf(regexp:Groups groups) returns string {
    regexp:Span? span = groups[1];
    return span is () ? "" : span.substring();
}

isolated function htmlEscape(string s) returns string =>
    re `'`.replaceAll(re `"`.replaceAll(re `>`.replaceAll(re `<`.replaceAll(re `&`.replaceAll(s, "&amp;"),
            "&lt;"), "&gt;"), "&quot;"), "&#39;");
