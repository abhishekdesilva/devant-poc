# POC 1 — Client IP via X-Forwarded-For (Bijira + Devant)

## Why this is needed
Bijira (API gateway) and Devant (app/integration runtime) both sit in front
of your backend as reverse proxies. `http:Caller.remoteAddress` at your
service will always report the *previous hop's* IP (the gateway container),
never the original caller. The only place the real client IP survives is the
`X-Forwarded-For` header, which each hop appends to rather than overwrites.

## Run it
```bash
bal run service.bal
```

## Test it
```bash
# Simulating what Bijira/Devant would send after proxying a real client at 203.0.113.7
curl -H "X-Forwarded-For: 203.0.113.7, 10.20.30.1" http://localhost:9090/orders/client-ip
# -> {"resolvedClientIp":"203.0.113.7", ...}

# No proxy in front (direct call) — falls back to the TCP peer
curl http://localhost:9090/orders/client-ip
# -> {"resolvedClientIp":"127.0.0.1", ...}
```

## Seeing the full chain in the Devant logs
Every request also logs the complete forwarding chain — one summary line plus
one line per `X-Forwarded-For` hop — and returns the same data in the response
under `forwardingChain`:
```
message="X-Forwarded-For chain" rawXForwardedFor="203.0.113.7, 52.10.20.30, 172.70.1.1" hopCount=3 hops=[...] xRealIp=... cfConnectingIp=... remoteAddress=...
message="X-Forwarded-For hop" index=0 ip="203.0.113.7" position="original client (left-most)"
message="X-Forwarded-For hop" index=1 ip="52.10.20.30" position="intermediate proxy"
message="X-Forwarded-For hop" index=2 ip="172.70.1.1" position="last proxy before Devant (right-most)"
```
Besides XFF it captures `X-Real-IP`, `Forwarded`, `CF-Connecting-IP`,
`True-Client-IP`, `X-Envoy-External-Address`, and the TCP peer address. If a
proxy sends `X-Forwarded-For` as separate headers, they are joined in order.
In Devant: integration → **Observability → Logs**, search for `X-Forwarded-For`.

## Notes for the real Bijira/Devant deployment
- Confirm in your specific Bijira project/environment whether `X-Forwarded-For`
  is passed through untouched or rewritten — Envoy-based gateways (which both
  Bijira and Devant are built on) append to XFF by default rather than
  replacing it, matching RFC 7239 behavior.
- Only trust the left-most XFF entry if Bijira/Devant is the **only** ingress
  path into your network — otherwise a caller could forge earlier hops in the
  header before it ever reaches the gateway. If that's a concern, only trust
  the entry added by your own gateway (second-from-right, if you know exactly
  how many trusted proxies are in the chain) rather than the first.
