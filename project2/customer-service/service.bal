import ballerina/http;
import ballerina/log;

// ---------------------------------------------------------------------------
// POC 7 target: Customer Service (Project2), endpoint visibility = Organization.
// With Organization visibility, any component in the organization can call it, through the internal gateway with an OAuth token or API key.
//
// The response includes a "caller" section describing what reached this
// service (credentials present, gateway JWT claims), so the caller can show
// how each visibility level authenticates. Token values are never returned.
// ---------------------------------------------------------------------------

configurable int port = 9092;

const string SERVICE_NAME = "customer-service";
const string VISIBILITY = "Organization";

type Item record {| string id; string name; string tier; |};

service /customers on new http:Listener(port) {

    resource function get [string id](http:Request req) returns json {
        CallerInfo caller = describeCaller(req);
        log:printInfo("customer requested", customerId = id, gatewayJwt = caller.gatewayJwt is GatewayJwt);
        Item customer = {id, name: "Ada Lovelace", tier: "GOLD"};
        return {'service: SERVICE_NAME, visibility: VISIBILITY, customer, caller: caller.toJson()};
    }
}
