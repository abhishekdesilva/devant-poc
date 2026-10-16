import ballerina/http;
import ballerina/log;
import ballerina/os;
import ballerina/time;

// ---------------------------------------------------------------------------
// POC 7: Integration-to-integration calls in Devant, one per endpoint
// visibility level.
//
//   Project1 caller-integration ──▶ order-service      (Project1, Project)
//                               ──▶ customer-service   (Project2, Organization)
//                               ──▶ inventory-service  (Project2, Public)
//
// Each target is wired in with a Devant Connection. A connection provides the
// service URL and, for Organization/Public endpoints, credentials (OAuth
// client credentials or an API key). Values come from configurables set in
// Devant (Configs & Secrets), or from environment variables mapped from the
// connection; a configurable wins when both are set.
// ---------------------------------------------------------------------------

configurable int port = 9090;
configurable int timeoutSeconds = 10;

// Project visibility (same project): URL only, no credentials.
configurable string orderServiceUrl = "";

// Organization visibility (another project): URL + OAuth or API key.
configurable string customerServiceUrl = "";
configurable string customerTokenUrl = "";
configurable string customerClientId = "";
configurable string customerClientSecret = "";
configurable string customerApiKey = "";

// Public visibility: URL + OAuth or API key.
configurable string inventoryServiceUrl = "";
configurable string inventoryTokenUrl = "";
configurable string inventoryClientId = "";
configurable string inventoryClientSecret = "";
configurable string inventoryApiKey = "";

const string API_KEY_HEADER = "Choreo-API-Key";

type Target record {|
    string name;
    string visibility;
    string path;
    http:Client? 'client;
    string apiKey;
    string auth;
|};

type TargetResult record {|
    string target;
    string visibility;
    string auth;
    boolean ok;
    int? status = ();
    decimal latencyMs;
    json response = ();
    string? 'error = ();
|};

final Target orderTarget = check newTarget("order-service", "Project", "/orders",
        orderServiceUrl, "ORDER_SERVICE_URL", "", "", "", "", "", "", "", "");
final Target customerTarget = check newTarget("customer-service", "Organization", "/customers",
        customerServiceUrl, "CUSTOMER_SERVICE_URL",
        customerTokenUrl, "CUSTOMER_TOKEN_URL", customerClientId, "CUSTOMER_CLIENT_ID",
        customerClientSecret, "CUSTOMER_CLIENT_SECRET", customerApiKey, "CUSTOMER_API_KEY");
final Target inventoryTarget = check newTarget("inventory-service", "Public", "/inventory",
        inventoryServiceUrl, "INVENTORY_SERVICE_URL",
        inventoryTokenUrl, "INVENTORY_TOKEN_URL", inventoryClientId, "INVENTORY_CLIENT_ID",
        inventoryClientSecret, "INVENTORY_CLIENT_SECRET", inventoryApiKey, "INVENTORY_API_KEY");

service /demo on new http:Listener(port) {

    // GET /demo/orders/{id}: Project visibility (same project)
    resource function get orders/[string id]() returns TargetResult => call(orderTarget, id);

    // GET /demo/customers/{id}: Organization visibility (another project)
    resource function get customers/[string id]() returns TargetResult => call(customerTarget, id);

    // GET /demo/inventory/{sku}: Public visibility
    resource function get inventory/[string sku]() returns TargetResult => call(inventoryTarget, sku);

    // GET /demo/all?id=1: calls all three in parallel
    resource function get all(string id = "1") returns TargetResult[]|error {
        future<TargetResult> o = start call(orderTarget, id);
        future<TargetResult> c = start call(customerTarget, id);
        future<TargetResult> i = start call(inventoryTarget, id);
        TargetResult orderResult = check wait o;
        TargetResult customerResult = check wait c;
        TargetResult inventoryResult = check wait i;
        return [orderResult, customerResult, inventoryResult];
    }
}

function call(Target target, string id) returns TargetResult {
    http:Client? 'client = target.'client;
    if 'client is () {
        return {target: target.name, visibility: target.visibility, auth: target.auth, ok: false, latencyMs: 0,
                'error: "not configured: set the service URL (see README)"};
    }
    map<string> headers = target.apiKey == "" ? {} : {[API_KEY_HEADER]: target.apiKey};
    decimal started = time:monotonicNow();
    http:Response|error response = 'client->get(string `${target.path}/${id}`, headers);
    decimal latencyMs = (time:monotonicNow() - started) * 1000;

    TargetResult result = {target: target.name, visibility: target.visibility, auth: target.auth,
            ok: false, latencyMs: latencyMs.round(1)};
    if response is error {
        log:printError("call failed", target = target.name, 'error = response);
        result.'error = response.message();
        return result;
    }
    result.status = response.statusCode;
    result.ok = response.statusCode == http:STATUS_OK;
    json|error body = response.getJsonPayload();
    result.response = body is json ? body : ();
    log:printInfo("call completed", target = target.name, visibility = target.visibility,
            status = response.statusCode, latencyMs = result.latencyMs);
    return result;
}

// Builds the HTTP client for a target. OAuth client credentials when a client
// ID is set (the client fetches and renews the token itself); otherwise an API
// key header when set; otherwise no credentials (Project visibility).
function newTarget(string name, string visibility, string path,
        string url, string urlEnv, string tokenUrl, string tokenUrlEnv,
        string clientId, string clientIdEnv, string clientSecret, string clientSecretEnv,
        string apiKey, string apiKeyEnv) returns Target|error {
    string serviceUrl = setting(url, urlEnv);
    string resolvedTokenUrl = setting(tokenUrl, tokenUrlEnv);
    string resolvedClientId = setting(clientId, clientIdEnv);
    string resolvedSecret = setting(clientSecret, clientSecretEnv);
    string resolvedApiKey = setting(apiKey, apiKeyEnv);

    if serviceUrl == "" {
        log:printWarn("target not configured", target = name);
        return {name, visibility, path, 'client: (), apiKey: "", auth: "none"};
    }
    http:ClientConfiguration config = {timeout: <decimal>timeoutSeconds};
    string auth = "none";
    if resolvedClientId != "" {
        config.auth = {tokenUrl: resolvedTokenUrl, clientId: resolvedClientId, clientSecret: resolvedSecret};
        auth = "oauth2-client-credentials";
    } else if resolvedApiKey != "" {
        auth = "api-key";
    }
    log:printInfo("target configured", target = name, visibility = visibility, auth = auth);
    return {name, visibility, path, 'client: check new (serviceUrl, config),
            apiKey: auth == "api-key" ? resolvedApiKey : "", auth};
}

function setting(string configured, string envName) returns string =>
    configured != "" ? configured : os:getEnv(envName);
