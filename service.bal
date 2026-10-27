import ballerina/http;
import ballerina/log;

// ---------------------------------------------------------------------------
// POC 1: Read the real client IP at the backend, when the request has come
// through the Bijira API gateway and/or a Devant-hosted service in front of
// this one.
//
// Bijira (and Devant, both Envoy-based) sit between the caller and this
// service and terminate the client's TCP connection, so http:Caller's
// remoteAddress here is always the *gateway's* IP, never the caller's.
// The real client IP is carried forward in the X-Forwarded-For header,
// appended to by every proxy hop: "<original-client>, <hop-1>, <hop-2>, ...".
// We take the left-most (oldest / original) entry.
// ---------------------------------------------------------------------------

const string XFF_HEADER = "X-Forwarded-For";
const string REAL_IP_HEADER = "X-Real-IP"; // some gateways/CDNs set this too

// Other headers that carry client-IP information along the
// client -> Bijira -> Cloudflare -> Devant path. Logged for diagnostics only.
const string FORWARDED_HEADER = "Forwarded"; // RFC 7239 structured form
const string CF_CONNECTING_IP_HEADER = "CF-Connecting-IP"; // set by Cloudflare
const string TRUE_CLIENT_IP_HEADER = "True-Client-IP"; // Cloudflare Enterprise / Akamai
const string ENVOY_EXTERNAL_ADDRESS_HEADER = "X-Envoy-External-Address"; // set by Envoy edge proxies

service /orders on new http:Listener(9090) {

    resource function get client\-ip(http:Caller caller, http:Request req) returns error? {
        ForwardingChain chain = logForwardingChain(req, caller);
        string clientIp = extractClientIp(req, caller);

        log:printInfo("resolved client IP", clientIp = clientIp);

        json payload = {
            resolvedClientIp: clientIp,
            forwardingChain: chain.toJson(),
            note: "Trust this value only if the gateway (Bijira/Devant) is the sole entry point " +
                  "into this network; otherwise XFF can be spoofed by the caller."
        };
        check caller->respond(payload);
    }
}

// Everything this service can see about the proxy chain a request came through.
type ForwardingChain record {|
    string? rawXForwardedFor;
    string[] xForwardedForHops;
    string? xRealIp;
    string? forwarded;
    string? cfConnectingIp;
    string? trueClientIp;
    string? envoyExternalAddress;
    string remoteAddress;
|};

// Logs the full X-Forwarded-For chain (one summary line plus one line per
// hop) and the other client-IP headers, so the Devant logs show exactly
// which IP each proxy hop (Cloudflare/Bijira/Devant) appended.
function logForwardingChain(http:Request req, http:Caller caller) returns ForwardingChain {
    string? rawXff = getHeaderValue(req, XFF_HEADER);
    string[] hops = [];
    if rawXff is string {
        hops = re `,`.split(rawXff).map(hop => hop.trim()).filter(hop => hop != "");
    }

    ForwardingChain chain = {
        rawXForwardedFor: rawXff,
        xForwardedForHops: hops,
        xRealIp: getHeaderValue(req, REAL_IP_HEADER),
        forwarded: getHeaderValue(req, FORWARDED_HEADER),
        cfConnectingIp: getHeaderValue(req, CF_CONNECTING_IP_HEADER),
        trueClientIp: getHeaderValue(req, TRUE_CLIENT_IP_HEADER),
        envoyExternalAddress: getHeaderValue(req, ENVOY_EXTERNAL_ADDRESS_HEADER),
        remoteAddress: caller.remoteAddress.host
    };

    log:printInfo("X-Forwarded-For chain",
            rawXForwardedFor = chain.rawXForwardedFor,
            hopCount = hops.length(),
            hops = hops,
            xRealIp = chain.xRealIp,
            forwarded = chain.forwarded,
            cfConnectingIp = chain.cfConnectingIp,
            trueClientIp = chain.trueClientIp,
            envoyExternalAddress = chain.envoyExternalAddress,
            remoteAddress = chain.remoteAddress);

    foreach int i in 0 ..< hops.length() {
        string position = i == 0 ? "original client (left-most)"
            : i == hops.length() - 1 ? "last proxy before Devant (right-most)" : "intermediate proxy";
        log:printInfo("X-Forwarded-For hop", index = i, ip = hops[i], position = position);
    }

    return chain;
}

// Returns all values of a header joined with ", " (a proxy may send the
// header more than once instead of appending), or () if it is absent.
function getHeaderValue(http:Request req, string name) returns string? {
    string[]|http:HeaderNotFoundError values = req.getHeaders(name);
    if values is http:HeaderNotFoundError {
        return ();
    }
    return string:'join(", ", ...values);
}

// Extracts the originating client IP, preferring XFF (set by Bijira/Devant),
// falling back to X-Real-IP, then to the direct TCP peer as a last resort
// (only correct if nothing is proxying the request).
function extractClientIp(http:Request req, http:Caller caller) returns string {
    string|http:HeaderNotFoundError xff = req.getHeader(XFF_HEADER);
    if xff is string {
        // First entry = original client; later entries were added by each
        // intermediate proxy (e.g. "203.0.113.7, 10.20.30.1" -> 10.20.30.1
        // is the Bijira/Devant gateway hop, 203.0.113.7 is the caller).
        string[] hops = re `,\s*`.split(xff);
        if hops.length() > 0 {
            return hops[0].trim();
        }
    }

    string|http:HeaderNotFoundError realIp = req.getHeader(REAL_IP_HEADER);
    if realIp is string {
        return realIp.trim();
    }

    return caller.remoteAddress.host;
}
