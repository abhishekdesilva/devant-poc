import ballerina/http;
import ballerina/log;
import choreo/mediation;

// ---------------------------------------------------------------------------
// POC 5: Bijira request-flow mediation policy that logs the client-IP view
// the Bijira gateway has of a request, before it is forwarded to the backend
// (Devant). Counterpart to POC 1, which logs the same headers on the Devant
// side — comparing the two shows which hop loses the real client IP.
//
// Optionally (Client IP Header set), it also stamps the resolved client IP
// into a custom header so it survives proxies downstream that rewrite
// X-Forwarded-For. Leave it empty for log-only mode.
//
// How the client IP is resolved (Client IP Source):
//   cf-connecting-ip (default)  CF-Connecting-IP, which Cloudflare sets on every
//                               request; if it's missing or invalid, falls back to xff.
//   xff                         X-Forwarded-For, read from the right, skipping private
//                               and internal addresses (proxies inside the platform);
//                               the first public address is the client.
// Neither depends on how many internal hops the platform adds, which varies.
// Both assume the gateway is only reachable through Cloudflare; otherwise a
// caller could send their own CF-Connecting-IP.
// ---------------------------------------------------------------------------

const string HEADER_X_REQUEST_ID = "x-request-id";
const string XFF_HEADER = "X-Forwarded-For";
const string CF_CONNECTING_IP = "CF-Connecting-IP";

const string SOURCE_CF = "cf-connecting-ip";
const string SOURCE_XFF = "xff";

// Other headers that can carry client-IP information. Logged for diagnostics only.
const string[] IP_HEADERS = ["X-Real-IP", "Forwarded", "X-Envoy-External-Address", "CF-Connecting-IP", "True-Client-IP"];

@mediation:RequestFlow
public function logClientIp(mediation:Context ctx, http:Request req, string Client\ IP\ Header = "",
        string Client\ IP\ Source = "cf-connecting-ip") returns http:Response|false|error|() {
    string? rawXff = getHeaderValue(req, XFF_HEADER);
    string[] hops = parseHops(rawXff);

    map<string?> otherHeaders = {};
    foreach string name in IP_HEADERS {
        otherHeaders[name] = getHeaderValue(req, name);
    }

    log:printInfo("Bijira X-Forwarded-For chain",
            requestId = getHeaderValue(req, HEADER_X_REQUEST_ID) ?: "<request-id-unavailable>",
            httpMethod = req.method,
            resourcePath = ctx.resourcePath().toString(),
            rawXForwardedFor = rawXff,
            hopCount = hops.length(),
            hops = hops,
            otherIpHeaders = otherHeaders);

    foreach int i in 0 ..< hops.length() {
        string hop = hops[i];
        log:printInfo("Bijira X-Forwarded-For hop", index = i, ip = hop, indexFromRight = hops.length() - 1 - i,
                'private = isPrivateOrInternal(normalizeIp(hop) ?: hop));
    }

    if Client\ IP\ Header == "" {
        return ();
    }

    // Never forward a caller-supplied value for the header we own.
    req.removeHeader(Client\ IP\ Header);
    string 'source = Client\ IP\ Source.trim().toLowerAscii();
    if 'source == "" {
        'source = SOURCE_CF;
    }
    if 'source != SOURCE_CF && 'source != SOURCE_XFF {
        log:printWarn("Bijira client IP not stamped: Client IP Source must be 'cf-connecting-ip' or 'xff'",
                clientIpSource = Client\ IP\ Source);
        return ();
    }

    [string, string]? resolved = resolveClientIp('source, getHeaderValue(req, CF_CONNECTING_IP), hops);
    if resolved is () {
        log:printWarn("Bijira client IP not stamped: no public client address found",
                clientIpSource = 'source, hopCount = hops.length());
        return ();
    }
    [string, string] [clientIp, resolvedFrom] = resolved;
    req.setHeader(Client\ IP\ Header, clientIp);
    log:printInfo("Bijira client IP stamped", header = Client\ IP\ Header, clientIp = clientIp,
            resolvedFrom = resolvedFrom);
    return ();
}

// Returns the client IP and where it came from ("cf-connecting-ip" or "xff"),
// or () if neither source yields a public address.
function resolveClientIp(string 'source, string? cfConnectingIp, string[] hops) returns [string, string]? {
    if 'source == SOURCE_CF && cfConnectingIp is string {
        string? ip = normalizeIp(cfConnectingIp);
        if ip is string {
            return [ip, SOURCE_CF];
        }
    }
    string? fromXff = rightmostPublicHop(hops);
    if fromXff is string {
        return [fromXff, SOURCE_XFF];
    }
    return ();
}

// Walks X-Forwarded-For from the right (the hop added closest to the gateway)
// and returns the first address that isn't private or internal. Entries
// added by the caller are further left, so they can't override it.
function rightmostPublicHop(string[] hops) returns string? {
    foreach int i in 0 ..< hops.length() {
        string? ip = normalizeIp(hops[hops.length() - 1 - i]);
        if ip is string && !isPrivateOrInternal(ip) {
            return ip;
        }
    }
    return ();
}

// Accepts "1.2.3.4", "1.2.3.4:5678", "2402:d000::1" and "[2402:d000::1]:443";
// returns the bare address, or () if the value isn't an IP address.
function normalizeIp(string value) returns string? {
    string v = value.trim();
    if v.startsWith("[") {
        int? close = v.indexOf("]");
        if close is () {
            return ();
        }
        v = v.substring(1, close);
    } else if isIpv4WithPort(v) {
        int? colon = v.indexOf(":");
        if colon is int {
            v = v.substring(0, colon);
        }
    }
    if parseIpv4(v) is int[] || isIpv6(v) {
        return v.toLowerAscii();
    }
    return ();
}

function isIpv4WithPort(string v) returns boolean {
    int? colon = v.indexOf(":");
    return colon is int && v.lastIndexOf(":") == colon && parseIpv4(v.substring(0, colon)) is int[];
}

// Returns the four octets of a dotted IPv4 address, or () if it isn't one.
function parseIpv4(string v) returns int[]? {
    string[] parts = re `\.`.split(v);
    if parts.length() != 4 {
        return ();
    }
    int[] octets = [];
    foreach string part in parts {
        if part.length() == 0 || part.length() > 3 || !re `[0-9]+`.isFullMatch(part) {
            return ();
        }
        int|error n = int:fromString(part);
        if n is error || n > 255 {
            return ();
        }
        octets.push(n);
    }
    return octets;
}

function isIpv6(string v) returns boolean =>
    v.includes(":") && re `[0-9A-Fa-f:.]+`.isFullMatch(v) && v.length() <= 45;

// Private, loopback, link-local, carrier-grade NAT and unique-local ranges:
// addresses of proxies inside a network, never a client's public address.
function isPrivateOrInternal(string ip) returns boolean {
    int[]? v4 = parseIpv4(ip);
    if v4 is int[] {
        int a = v4[0];
        int b = v4[1];
        return a == 10 || a == 127 || a == 0
            || (a == 172 && b >= 16 && b <= 31)
            || (a == 192 && b == 168)
            || (a == 169 && b == 254)
            || (a == 100 && b >= 64 && b <= 127);
    }
    string v6 = ip.toLowerAscii();
    if v6.startsWith("::ffff:") {
        // IPv4-mapped IPv6 address
        return isPrivateOrInternal(v6.substring(7));
    }
    return v6 == "::1" || v6 == "::"
        || v6.startsWith("fc") || v6.startsWith("fd")
        || v6.startsWith("fe8") || v6.startsWith("fe9") || v6.startsWith("fea") || v6.startsWith("feb");
}

// Splits an X-Forwarded-For value into trimmed, non-empty hops, left (oldest) to right (newest).
function parseHops(string? rawXff) returns string[] {
    if rawXff is () {
        return [];
    }
    return re `,`.split(rawXff).map(hop => hop.trim()).filter(hop => hop != "");
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
