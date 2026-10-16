import ballerina/http;
import ballerina/jwt;

// Header the Devant/Bijira gateway uses to pass the verified caller's
// identity to the backend (see POC 2).
const string GATEWAY_JWT_HEADER = "x-jwt-assertion";
const string API_KEY_HEADER = "Choreo-API-Key";

type GatewayJwt record {|
    string? issuer;
    string? subject;
    string|string[]? audience;
|};

type CallerInfo record {|
    // True when the request still carries these headers. Behind the Devant
    // gateway they are usually consumed there; locally they arrive as sent.
    boolean authorizationHeader;
    boolean apiKeyHeader;
    // Present when the call came through the Devant gateway (Organization or
    // Public visibility). Absent for Project visibility calls.
    GatewayJwt? gatewayJwt;
|};

function describeCaller(http:Request req) returns CallerInfo {
    GatewayJwt? gatewayJwt = ();
    string|http:HeaderNotFoundError assertion = req.getHeader(GATEWAY_JWT_HEADER);
    if assertion is string {
        [jwt:Header, jwt:Payload]|jwt:Error decoded = jwt:decode(assertion);
        if decoded is [jwt:Header, jwt:Payload] {
            jwt:Payload payload = decoded[1];
            gatewayJwt = {issuer: payload.iss, subject: payload.sub, audience: payload.aud};
        }
    }
    return {
        authorizationHeader: req.hasHeader(http:AUTH_HEADER),
        apiKeyHeader: req.hasHeader(API_KEY_HEADER),
        gatewayJwt
    };
}
