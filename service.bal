import ballerina/http;
import ballerina/jwt;
import ballerina/log;

// ---------------------------------------------------------------------------
// POC 2: Read the end-user JWT that Bijira generates and forwards to a
// backend service running on Devant.
//
// When Bijira fronts an API and the request is authenticated (OAuth2/API
// key/JWT at the edge), the gateway mints a *backend JWT* asserting the
// caller's identity/claims and forwards it to the upstream service in the
// `X-JWT-Assertion` header (the same convention used across the WSO2
// API Manager / Choreo / Devant lineage that Bijira's gateway is built on)
// — separate from any `Authorization` header the client itself sent.
//
// Two modes are shown:
//   1. decodeOnly  — just read the claims (fast, no trust decision made).
//      Safe ONLY because Devant/Bijira sit on a network path you trust and
//      strip/overwrite any client-supplied X-JWT-Assertion before it
//      reaches you.
//   2. validateSignature — cryptographically verify the JWT against
//      Bijira's JWKS endpoint before trusting any claim. Use this if the
//      request could also reach this service by a path that bypasses
//      Bijira/Devant.
// ---------------------------------------------------------------------------

const string JWT_ASSERTION_HEADER = "X-JWT-Assertion";

// Replace with the actual JWKS endpoint for your Bijira organization/env,
// e.g. https://gateway.<region>.bijira.dev/.wellknown/jwks or the Devant
// project's equivalent — confirm the exact URL in your Bijira console.
configurable string jwksUrl = "https://gateway.example-bijira-env.dev/.wellknown/jwks";

listener http:Listener devantServiceListener = new (9091);

service /profile on devantServiceListener {

    // Mode 1: decode-only — trust the network boundary.
    resource function get whoami(http:Request req) returns json|http:BadRequest {
        string|http:HeaderNotFoundError assertion = req.getHeader(JWT_ASSERTION_HEADER);
        if assertion is http:HeaderNotFoundError {
            return <http:BadRequest>{
                body: {message: "Missing " + JWT_ASSERTION_HEADER + " header — is this service being called via Bijira/Devant?"}
            };
        }

        [jwt:Header, jwt:Payload]|jwt:Error decoded = jwt:decode(assertion);
        if decoded is jwt:Error {
            log:printError("failed to decode JWT from " + JWT_ASSERTION_HEADER, decoded);
            return <http:BadRequest>{body: {message: "Malformed JWT"}};
        }

        jwt:Payload payload = decoded[1];
        return <json>{
            subject: payload.sub,
            issuer: payload.iss,
            issuedAt: payload.iat,
            expiresAt: payload.exp,
            // Custom / WSO2 claims land in the open map.
            applicationName: <json>payload["http://wso2.org/claims/applicationname"],
            apiName: <json>payload["http://wso2.org/claims/apiname"],
            x: <json>payload["email"]
        };
    }

    // Mode 2: verify signature + standard claims before trusting anything.
    resource function get secureWhoami(http:Request req) returns json|http:Unauthorized|http:BadRequest {
        string|http:HeaderNotFoundError assertion = req.getHeader(JWT_ASSERTION_HEADER);
        if assertion is http:HeaderNotFoundError {
            return <http:BadRequest>{body: {message: "Missing " + JWT_ASSERTION_HEADER + " header"}};
        }

        jwt:ValidatorConfig validatorConfig = {
            issuer: "https://gateway.example-bijira-env.dev", // set to Bijira's actual issuer
            audience: "devant-profile-service", // the audience Bijira mints this JWT for
            signatureConfig: {
                jwksConfig: {url: jwksUrl}
            }
        };

        jwt:Payload|jwt:Error payload = jwt:validate(assertion, validatorConfig);
        if payload is jwt:Error {
            log:printError("JWT validation failed", payload);
            return <http:Unauthorized>{body: {message: "Invalid or expired token"}};
        }

        return <json>{
            subject: payload.sub,
            verified: true,
            applicationName: <json>payload["http://wso2.org/claims/applicationname"]
        };
    }
}
