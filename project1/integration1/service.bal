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

// With a consumer key, the client gets an OAuth token (client credentials),
// caches it and renews it automatically. Without one, it calls without a
// token, which is only useful for a local run.
final http:Client integration2 = check new (integration2Url,
        consumerKey == "" ? {} : {auth: {tokenUrl, clientId: consumerKey, clientSecret: consumerSecret}});

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
    log:printInfo("integration1 started", integration2Url = integration2Url,
            auth = consumerKey == "" ? "none" : "oauth2-client-credentials");
}
