import ballerina/http;
import ballerina/log;
import ballerina/url;

// Integration 1 (Project1): calls Integration 2 in Project2 and returns its
// response. The values come from the Devant Connection to Integration 2, set
// as configurables on this integration. A connection provides either an API
// key (ServiceURL + ChoreoAPIKey) or OAuth credentials (ServiceURL + token
// URL + consumer key + consumer secret), depending on how it was created.

configurable int port = 9090;
configurable string integration2Url = ?;       // Connection: ServiceURL
configurable string choreoApiKey = "";         // Connection: ChoreoAPIKey (secret)
configurable string tokenUrl = "";             // Connection: token URL (OAuth connections)
configurable string consumerKey = "";          // Connection: consumer key (secret, OAuth connections)
configurable string consumerSecret = "";       // Connection: consumer secret (secret, OAuth connections)

// TLS to Integration 2's gateway. By default the certificate is checked
// against the standard trust store. If the gateway uses a private CA, mount
// its PEM certificate as a file and set the path here.
configurable string integration2CaCertFile = "";
// Diagnosis only: false skips certificate checks. Never use it in production.
configurable boolean integration2VerifyTls = true;

const string API_KEY_HEADER = "Choreo-API-Key";

// API key if set; otherwise OAuth client credentials if a consumer key is set
// (the client gets the token, caches it and renews it); otherwise no
// credentials, which is only useful for a local run.
final string authMode = choreoApiKey != "" ? "api-key" : consumerKey != "" ? "oauth2-client-credentials" : "none";
final map<string> authHeaders = authMode == "api-key" ? {[API_KEY_HEADER]: choreoApiKey} : {};
final http:Client integration2 = check new (integration2Url, clientConfig());

function clientConfig() returns http:ClientConfiguration {
    http:ClientConfiguration config = {};
    if authMode == "oauth2-client-credentials" {
        config.auth = {tokenUrl, clientId: consumerKey, clientSecret: consumerSecret};
    }
    if !integration2VerifyTls {
        config.secureSocket = {enable: false};
    } else if integration2CaCertFile != "" {
        config.secureSocket = {cert: integration2CaCertFile};
    }
    return config;
}

service /hello on new http:Listener(port) {

    // GET /hello?name=Provident
    resource function get .(string name = "World") returns json|http:BadGateway|error {
        string query = check url:encode(name, "UTF-8");
        json|error reply = integration2->get(string `?name=${query}`, authHeaders);
        if reply is http:ClientRequestError|http:RemoteServerError {
            // Integration 2 (or its gateway) answered with 4xx/5xx. Pass on its status
            // and error body, e.g. the gateway's error code. These contain no tokens.
            int status = reply.detail().statusCode;
            anydata upstream = reply.detail().body;
            log:printError("integration2 returned an error", status = status, upstream = upstream.toString());
            return <http:BadGateway>{body: {message: "Integration 2 call failed", reason: reply.message(),
                    upstreamStatus: status, upstreamBody: upstream.toJson()}};
        }
        if reply is error {
            log:printError("call to integration2 failed", 'error = reply);
            return <http:BadGateway>{body: {message: "Integration 2 call failed", reason: reply.message()}};
        }
        return {servedBy: "integration1", project: "Project1", integration2Response: reply};
    }
}

function init() {
    string tls = !integration2VerifyTls ? "NOT VERIFIED" : integration2CaCertFile != "" ? "custom CA" : "default trust store";
    log:printInfo("integration1 started", integration2Url = integration2Url, auth = authMode, tls = tls);
    if authMode == "api-key" && consumerKey != "" {
        log:printWarn("both choreoApiKey and consumerKey are set; using the API key");
    }
    if !integration2VerifyTls {
        log:printWarn("TLS certificate checks to Integration 2 are disabled; use only to diagnose");
    }
}
