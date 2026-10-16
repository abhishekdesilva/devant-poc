import ballerina/http;
import ballerina/log;

// ---------------------------------------------------------------------------
// POC 7 target: Order Service (Project1), endpoint visibility = Project.
// With Project visibility, only components in Project1 can call it, over the internal network with no credentials.
//
// The response includes a "caller" section describing what reached this
// service (credentials present, gateway JWT claims), so the caller can show
// how each visibility level authenticates. Token values are never returned.
// ---------------------------------------------------------------------------

configurable int port = 9091;

const string SERVICE_NAME = "order-service";
const string VISIBILITY = "Project";

type Item record {| string id; string status; decimal total; |};

service /orders on new http:Listener(port) {

    resource function get [string id](http:Request req) returns json {
        CallerInfo caller = describeCaller(req);
        log:printInfo("order requested", orderId = id, gatewayJwt = caller.gatewayJwt is GatewayJwt);
        Item 'order = {id, status: "SHIPPED", total: 120.50};
        return {'service: SERVICE_NAME, visibility: VISIBILITY, 'order, caller: caller.toJson()};
    }
}
