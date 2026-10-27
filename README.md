# Log X-Forwarded-For Header

Request-flow mediation policy that logs the client-IP view **Bijira** has of a request
just before it is forwarded to the backend (Devant). Pair it with POC 1, which logs the
same headers on the Devant side: comparing the two shows which hop loses the real client IP.

It can also stamp the resolved client IP into a custom header (e.g. `X-Client-IP`) that
survives downstream proxies rewriting `X-Forwarded-For` — leave that off until the logs
show which hop holds the real IP.

## Parameters (set when attaching the policy)
| Parameter | Default | Meaning |
|---|---|---|
| `Client IP Header` | *(empty)* | Empty = log only. Set (e.g. `X-Client-IP`) to remove any caller-supplied value and stamp the resolved IP. |
| `Client IP Source` | `cf-connecting-ip` | How the client IP is resolved (below). `cf-connecting-ip` or `xff`. |

### How the client IP is resolved (version 1.1.1 and later)
- **`cf-connecting-ip`** (default): uses `CF-Connecting-IP`, which Cloudflare sets on every request
  and overwrites if the caller sends one. If it's missing or not an IP address, falls back to `xff`.
- **`xff`**: reads `X-Forwarded-For` from the right and skips private and internal addresses
  (`10.x`, `172.16–31.x`, `192.168.x`, `100.64–127.x`, `127.x`, `169.254.x`, and IPv6 `::1`,
  `fc00::/7`, `fe80::/10`). The first public address is the client. Entries a caller adds
  themselves are further left, so they can't override it.

Neither depends on how many internal hops the platform adds. That number varies: in testing, one
request arrived as `X-Forwarded-For: <client>` and another as `<client>, 10.128.11.5`, so the
fixed hop count of earlier versions (`Trusted Hops From Right`) picked the wrong entry. Both
modes assume the Bijira endpoint is only reachable through Cloudflare.

The client IP can be IPv6 (for example `2402:d000:…`) when the caller connects to Cloudflare over
IPv6. Clients behind a corporate proxy (such as Zscaler) appear as the proxy's public address.

## What it logs
```
message="Bijira X-Forwarded-For chain" requestId=... httpMethod="GET" resourcePath="/healthcheck" rawXForwardedFor="2402:d000:8114:bcd:dd3:345d:22e8:bda9, 10.128.11.5" hopCount=2 hops=[...] otherIpHeaders={"X-Real-IP":...,"Forwarded":...,"X-Envoy-External-Address":...,"CF-Connecting-IP":"2402:d000:8114:bcd:dd3:345d:22e8:bda9","True-Client-IP":...}
message="Bijira X-Forwarded-For hop" index=0 ip="2402:d000:8114:bcd:dd3:345d:22e8:bda9" indexFromRight=1 private=false
message="Bijira X-Forwarded-For hop" index=1 ip="10.128.11.5" indexFromRight=0 private=true
message="Bijira client IP stamped" header="X-Client-IP" clientIp="2402:d000:8114:bcd:dd3:345d:22e8:bda9" resolvedFrom="cf-connecting-ip"   # only when enabled
```
`resolvedFrom` shows which source was used. If no public address is found, a warning
`Bijira client IP not stamped: no public client address found` is logged and the header isn't set.

## Publish and attach
Prerequisites: Ballerina **2201.12.8** (the version Bijira supports for policies), Java 21, and a
Ballerina Central account. Put a Central access token in `~/.ballerina/settings.toml` or
`BALLERINA_CENTRAL_ACCESS_TOKEN`.

1. Set `org` in `Ballerina.toml` to **your Ballerina Central org name** (must match exactly).
2. Test, pack and publish:
   ```bash
   bal test
   bal pack
   bal push
   ```
   `visibility = "private"` limits the package to members of that Ballerina Central org. To share it with your team, publish it under a shared Central org they belong to; removing the line makes it public to everyone.
3. Bijira console → project → API proxy → **Develop → Policy**.
   - Resource level: click the attach-policy button on the resource (e.g. `GET /healthcheck`) →
     **Request flow** → **Attach Mediation Policy** → pick `client_ip_logger`.
   - Or API level: **Add API-level Policies** → **Attach Mediation Policy**.
   - Leave `Client IP Header` empty for log-only. **Add** → **Save**.
4. **Deploy → Configure & Deploy** → (optionally enable **Refresh Mediation Policies**) → **Save & Deploy**.
5. Call the proxy, then open **Observability → Logs** and select **Application Logs** (not
   Gateway Logs). The policy runs in a generated component named `mediation-<api name>`
   (e.g. `mediation-samplehealth`); search for `Bijira X-Forwarded-For`.

## Test calls
```bash
curl -s ifconfig.me; echo                                   # your real IP
curl -s "$BIJIRA_URL/healthcheck" -H "Authorization: Bearer $TOKEN"
curl -s "$BIJIRA_URL/healthcheck" -H "Authorization: Bearer $TOKEN" -H "X-Forwarded-For: 1.2.3.4"
```
- Your IP appears in `hops` and in `CF-Connecting-IP` → Bijira knows it. Compare it with
  `curl -s https://www.cloudflare.com/cdn-cgi/trace | grep ^ip=` (what Cloudflare sees, which may
  be IPv6), rather than an IPv4-only "what is my IP" site.
- With the spoofed call you see `1.2.3.4` added on the left → it's ignored by both modes.
- Only private IPs → Bijira's own load balancer hides the source; raise with the Bijira team.

Then enable stamping: edit the policy parameters to `Client IP Header = X-Client-IP` (keep
`Client IP Source = cf-connecting-ip`), save, redeploy, and have the Devant service read
`X-Client-IP` first. This is only trustworthy if the Devant endpoint accepts
traffic from Bijira alone (e.g. OAuth backend credentials only Bijira holds).

## Alternative: built-in Log Message policy
For a one-off look without publishing anything, attach Bijira's built-in **Log Message** policy
to the request flow with **Log Headers = true** (it masks `Authorization`). It logs every header
as one map, including `X-Forwarded-For`, but can't stamp a header.
