import ballerina/http;
import ballerina/log;

// ---------------------------------------------------------------------------
// POC 7 target: Inventory Service (Project2), endpoint visibility = Public.
// With Public visibility, anyone can call it through the public gateway, with an OAuth token or API key.
//
// The response includes a "caller" section describing what reached this
// service (credentials present, gateway JWT claims), so the caller can show
// how each visibility level authenticates. Token values are never returned.
// ---------------------------------------------------------------------------

configurable int port = 9093;

const string SERVICE_NAME = "inventory-service";
const string VISIBILITY = "Public";

type Item record {| string sku; int available; string warehouse; |};

service /inventory on new http:Listener(port) {

    resource function get [string id](http:Request req) returns json {
        CallerInfo caller = describeCaller(req);
        log:printInfo("item requested", sku = id, gatewayJwt = caller.gatewayJwt is GatewayJwt);
        Item item = {sku: id, available: 42, warehouse: "NJ-01"};
        return {'service: SERVICE_NAME, visibility: VISIBILITY, item, caller: caller.toJson()};
    }
}
