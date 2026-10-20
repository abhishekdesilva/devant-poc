import ballerina/http;
import ballerina/lang.'int as ints;
import ballerina/log;
import ballerina/os;
import ballerina/url;

// Integration 1 (Project1): calls Integration 2 in Project2 and returns its
// response. Also passes customer and email requests through to Integration 2.
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

// POST /customers body, passed through to Integration 2.
type NewCustomer record {|
    string name;
    string email;
|};

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
            return upstreamError(reply.detail().statusCode, reply.detail().body, reply.message());
        }
        if reply is error {
            return callFailed(reply);
        }
        return {servedBy: "integration1", project: "Project1", integration2Response: reply};
    }

    // The resources below pass requests through to Integration 2 in Project2,
    // so its customer and email features can be used from outside Devant.

    // POST /customers {"name": "...", "email": "..."}: registers a customer and sends the welcome email
    resource function post customers(@http:Payload NewCustomer body, http:Request req) returns http:Response|http:BadGateway {
        return forward(req, body.toJson());
    }

    // GET /customers?limit=20&offset=0
    resource function get customers(http:Request req, int 'limit = 20, int offset = 0) returns http:Response|http:BadGateway {
        return forward(req);
    }

    // GET /customers/{id}
    resource function get customers/[int id](http:Request req) returns http:Response|http:BadGateway {
        return forward(req);
    }

    // GET /emails: the mock email outbox, newest first
    resource function get emails(http:Request req) returns http:Response|http:BadGateway {
        return forward(req);
    }

    // GET /emails/{id}
    resource function get emails/[string id](http:Request req) returns http:Response|http:BadGateway {
        return forward(req);
    }

    // GET /emails/{id}/preview: the rendered email as an HTML page
    resource function get emails/[string id]/preview(http:Request req) returns http:Response|http:BadGateway {
        return forward(req);
    }
}

// Sends the request to the same path on Integration 2 (including the query
// string) and returns Integration 2's response unchanged, except for gateway
// rejections, which become a 502 so they aren't mistaken for the caller's own
// authentication failing.
function forward(http:Request req, json? body = ()) returns http:Response|http:BadGateway {
    http:Request out = new;
    if body !is () {
        out.setJsonPayload(body);
    }
    http:Response|error response = integration2->execute(req.method, req.rawPath, out, authHeaders);
    if response is error {
        return callFailed(response);
    }
    if response.statusCode == http:STATUS_UNAUTHORIZED || response.statusCode == http:STATUS_FORBIDDEN {
        json|error upstream = response.getJsonPayload();
        return upstreamError(response.statusCode, upstream is json ? upstream : (), response.reasonPhrase);
    }
    return response;
}

function upstreamError(int status, anydata upstream, string reason) returns http:BadGateway {
    log:printError("integration2 returned an error", status = status, upstream = upstream.toString());
    return {body: {message: "Integration 2 call failed", reason, upstreamStatus: status, upstreamBody: upstream.toJson()}};
}

function callFailed(error e) returns http:BadGateway {
    if e is http:IdleTimeoutError {
        log:printError("integration2 timed out", timeoutSeconds = timeoutSeconds);
        return {body: {message: "Integration 2 call failed",
                reason: string `Integration 2 did not respond within ${timeoutSeconds} seconds`}};
    }
    log:printError("call to integration2 failed", 'error = e);
    return {body: {message: "Integration 2 call failed", reason: e.message()}};
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
