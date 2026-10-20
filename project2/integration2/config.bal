import ballerina/os;

// Settings are environment variables (Devant: Configs & Secrets, Mount:
// Environment Variables). All are optional; the defaults run the POC with an
// in-memory database and the mock email outbox.
//
//   DB_URL                  JDBC URL. Default: in-memory H2 database, reset on restart.
//   DB_USER, DB_PASSWORD    Database login. Default: H2's "sa" with no password.
//   EMAIL_MODE              "mock" (default): emails go to the in-memory outbox.
//                           "smtp": emails are sent through the SMTP server below.
//   EMAIL_FROM              Sender address. Default: no-reply@example.com
//   COMPANY_NAME            Value of {{companyName}} in the template. Default: Provident Bank
//   SUPPORT_EMAIL           Value of {{supportEmail}} in the template. Default: support@example.com
//   EMAIL_SUBJECT_TEMPLATE  Subject template. Default: see templates.bal
//   EMAIL_TEMPLATE_FILE     Path to an HTML template file (e.g. a Devant file mount).
//                           Default: the built-in template in templates.bal
//   SMTP_HOST, SMTP_PORT, SMTP_USERNAME, SMTP_PASSWORD, SMTP_SECURITY
//                           Only for EMAIL_MODE=smtp. SMTP_SECURITY is one of
//                           START_TLS_AUTO (default), START_TLS_ALWAYS, START_TLS_NEVER, SSL.

final string dbUrl = setting("DB_URL", "jdbc:h2:mem:pocdb;DB_CLOSE_DELAY=-1");
final string dbUser = setting("DB_USER", "sa");
final string dbPassword = os:getEnv("DB_PASSWORD");

final string emailMode = setting("EMAIL_MODE", "mock").toLowerAscii();
final string emailFrom = setting("EMAIL_FROM", "no-reply@example.com");
final string companyName = setting("COMPANY_NAME", "Provident Bank");
final string supportEmail = setting("SUPPORT_EMAIL", "support@example.com");

function setting(string name, string default) returns string {
    string value = os:getEnv(name).trim();
    return value == "" ? default : value;
}
