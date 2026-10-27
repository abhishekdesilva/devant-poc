# POC 2 — Reading the Bijira-issued JWT in a Devant-hosted service

## Why this is needed
Bijira authenticates the caller at the edge (OAuth2/API key/JWT) and, on
proxying the request upstream to your Devant-deployed service, mints a
backend JWT carrying the verified caller's identity/claims. That token
travels in the `X-JWT-Assertion` header — the same convention WSO2 API
Manager / Choreo / Devant gateways use — separate from whatever
`Authorization` header the original client sent.

## Run it
```bash
bal run service.bal
```

## Test it (decode-only mode)
Generate a throwaway unsigned-looking JWT for local testing (any JWT with
three base64url segments works for the decode-only endpoint since it doesn't
verify the signature):
```bash
HEADER=$(echo -n '{"alg":"none","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-')
PAYLOAD=$(echo -n '{"sub":"alice@example.com","iss":"https://gateway.example-bijira-env.dev","iat":1700000000,"exp":9999999999,"http://wso2.org/claims/applicationname":"sample-app","email":"alice@example.com"}' | base64 | tr -d '=' | tr '/+' '_-')
JWT="$HEADER.$PAYLOAD."

curl -H "X-JWT-Assertion: $JWT" http://localhost:9091/profile/whoami
```

## Wiring it to real Bijira/Devant
1. In the Bijira console, confirm the exact header name your API proxy is
   configured to forward the backend JWT on (default across this WSO2
   lineage is `X-JWT-Assertion`, but it's configurable per-gateway).
2. Get the real JWKS URL and issuer for your Bijira org/environment and set
   `jwksUrl` (as a `Config.toml` value) plus the `issuer`/`audience` in
   `secureWhoami` — then switch your route to that endpoint so signatures are
   actually verified, not just trusted by network position.
3. Deploy this service as a Devant component; Bijira's API proxy should
   target it as the backend.
