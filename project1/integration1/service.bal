import ballerina/http;
import ballerina/lang.'int as ints;
import ballerina/log;
import ballerina/os;
import ballerina/url;

// Integration 1 (Project1): calls Integration 2 in Project2 and returns its
// response.
//
// Settings are environment variables, set in Devant under Configs & Secrets
// (Mount: Environment Variables), using the values of the Devant Connection
// to Integration 2. A connection provides either an API key (ServiceURL +
// ChoreoAPIKey) or OAuth credentials (ServiceURL + token URL + consumer key +
// consumer secret), depending on how it was created.
//
//   INTEGRATION2_URL               Connection: ServiceURL (required)
//   CHOREO_API_KEY                 Connection: ChoreoAPIKey (secret)
//   TOKEN_URL                      Connection: token URL (OAuth connections)
//   CONSUMER_KEY                   Connection: consumer key (secret, OAuth connections)
//   CONSUMER_SECRET                Connection: consumer secret (secret, OAuth connections)
//   INTEGRATION2_TIMEOUT_SECONDS   How long to wait for Integration 2 (default 30)
//   INTEGRATION2_CA_CERT_FILE      PEM of a private CA that signed Integration 2's gateway certificate
//   INTEGRATION2_VERIFY_TLS        "false" skips certificate checks. Diagnosis only.

configurable int port = 9090;

final string integration2Url = os:getEnv("INTEGRATION2_URL");
final string choreoApiKey = os:getEnv("CHOREO_API_KEY");
final string tokenUrl = os:getEnv("TOKEN_URL");
final string consumerKey = os:getEnv("CONSUMER_KEY");
final string consumerSecret = os:getEnv("CONSUMER_SECRET");
final string caCertFile = os:getEnv("INTEGRATION2_CA_CERT_FILE");
final boolean verifyTls = os:getEnv("INTEGRATION2_VERIFY_TLS").trim().toLowerAscii() != "false";
final int timeoutSeconds = check intSetting("INTEGRATION2_TIMEOUT_SECONDS", 30);

const string API_KEY_HEADER = "Choreo-API-Key";

// API key if set; otherwise OAuth client credentials if a consumer key is set
// (the client gets the token, caches it and renews it); otherwise no
// credentials, which is only useful for a local run.
final string authMode = choreoApiKey != "" ? "api-key" : consumerKey != "" ? "oauth2-client-credentials" : "none";
final map<string> authHeaders = authMode == "api-key" ? {[API_KEY_HEADER]: choreoApiKey} : {};
final http:Client integration2 = check newIntegration2Client();

service / on new http:Listener(port) {

    // GET /hello?name=Provident
    resource function get hello(string name = "World") returns json|http:BadGateway|error {
        string query = check url:encode(name, "UTF-8");
        json|error reply = integration2->get(string `/greeting?name=${query}`, authHeaders);
        if reply is http:ClientRequestError|http:RemoteServerError {
            // Integration 2 (or its gateway) answered with 4xx/5xx. Pass on its status
            // and error body, e.g. the gateway's error code. These contain no tokens.
            int status = reply.detail().statusCode;
            anydata upstream = reply.detail().body;
            log:printError("integration2 returned an error", status = status, upstream = upstream.toString());
            return <http:BadGateway>{body: {message: "Integration 2 call failed", reason: reply.message(),
                    upstreamStatus: status, upstreamBody: upstream.toJson()}};
        }
        if reply is http:IdleTimeoutError {
            log:printError("integration2 timed out", timeoutSeconds = timeoutSeconds);
            return <http:BadGateway>{body: {message: "Integration 2 call failed",
                    reason: string `Integration 2 did not respond within ${timeoutSeconds} seconds`}};
        }
        if reply is error {
            log:printError("call to integration2 failed", 'error = reply);
            return <http:BadGateway>{body: {message: "Integration 2 call failed", reason: reply.message()}};
        }
        return {servedBy: "integration1", project: "Project1", integration2Response: reply};
    }
}

function newIntegration2Client() returns http:Client|error {
    if integration2Url == "" {
        return error("INTEGRATION2_URL is not set. Add it in Devant under Configs & Secrets "
                + "(Mount: Environment Variables) with the connection's ServiceURL.");
    }
    http:ClientConfiguration config = {timeout: <decimal>timeoutSeconds};
    if authMode == "oauth2-client-credentials" {
        config.auth = {tokenUrl, clientId: consumerKey, clientSecret: consumerSecret};
    }
    if !verifyTls {
        config.secureSocket = {enable: false};
    } else if caCertFile != "" {
        config.secureSocket = {cert: caCertFile};
    }
    return new (integration2Url, config);
}

function intSetting(string name, int default) returns int|error {
    string value = os:getEnv(name).trim();
    if value == "" {
        return default;
    }
    int|error parsed = ints:fromString(value);
    if parsed is error || parsed <= 0 {
        return error(string `${name} must be a positive whole number of seconds, found '${value}'`);
    }
    return parsed;
}

function init() {
    string tls = !verifyTls ? "NOT VERIFIED" : caCertFile != "" ? "custom CA" : "default trust store";
    log:printInfo("integration1 started", integration2Url = integration2Url, auth = authMode, tls = tls,
            timeoutSeconds = timeoutSeconds);
    if authMode == "api-key" && consumerKey != "" {
        log:printWarn("both CHOREO_API_KEY and CONSUMER_KEY are set; using the API key");
    }
    if !verifyTls {
        log:printWarn("TLS certificate checks to Integration 2 are disabled; use only to diagnose");
    }
}
