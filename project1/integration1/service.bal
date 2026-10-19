import ballerina/http;
import ballerina/log;
import ballerina/url;

// Integration 1 (Project1): calls Integration 2 in Project2 and returns its
// response. The values come from the Devant Connection to Integration 2
// (service URL, token URL, consumer key and consumer secret), set as
// configurables on this integration.

configurable int port = 9090;
configurable string integration2Url = ?;       // Connection: service URL
configurable string tokenUrl = "";             // Connection: token URL
configurable string consumerKey = "";          // Connection: consumer key (secret)
configurable string consumerSecret = "";       // Connection: consumer secret (secret)

// TLS to Integration 2's gateway. By default the certificate is checked
// against the standard trust store. If the gateway uses a private CA, mount
// its PEM certificate as a file and set the path here.
configurable string integration2CaCertFile = "";
// Diagnosis only: false skips certificate checks. Never use it in production.
configurable boolean integration2VerifyTls = true;

final http:Client integration2 = check new (integration2Url, clientConfig());

// With a consumer key, the client gets an OAuth token (client credentials),
// caches it and renews it automatically. Without one, it calls without a
// token, which is only useful for a local run.
function clientConfig() returns http:ClientConfiguration {
    http:ClientConfiguration config = {};
    if consumerKey != "" {
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
        json|error reply = integration2->get(string `?name=${query}`);
        if reply is error {
            log:printError("call to integration2 failed", 'error = reply);
            return <http:BadGateway>{body: {message: "Integration 2 call failed", reason: reply.message()}};
        }
        return {servedBy: "integration1", project: "Project1", integration2Response: reply};
    }
}

function init() {
    string tls = !integration2VerifyTls ? "NOT VERIFIED" : integration2CaCertFile != "" ? "custom CA" : "default trust store";
    log:printInfo("integration1 started", integration2Url = integration2Url,
            auth = consumerKey == "" ? "none" : "oauth2-client-credentials", tls = tls);
    if !integration2VerifyTls {
        log:printWarn("TLS certificate checks to Integration 2 are disabled; use only to diagnose");
    }
}
