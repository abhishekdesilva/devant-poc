#!/usr/bin/env bash
# End-to-end check of the POC 6 API: health, list, create, read, update,
# duplicate, validation, delete, not-found.
#
#   ./scripts/api-test.sh                                   # local service
#   BASE_URL=https://<devant-or-bijira-url> TOKEN=<access token> ./scripts/api-test.sh
set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost:9090}"
AUTH=()
[[ -n "${TOKEN:-}" ]] && AUTH=(-H "Authorization: Bearer ${TOKEN}")
EMAIL="poc-test-$(date +%s)@example.com"
PASS=0
FAIL=0

call() { # method path [body] -> sets STATUS and BODY
    local method=$1 path=$2 body=${3:-}
    local args=(-s -w $'\n%{http_code}' -X "$method" "${AUTH[@]+"${AUTH[@]}"}" "${BASE_URL}${path}")
    [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" -d "$body")
    local out
    out=$(curl "${args[@]}")
    STATUS=${out##*$'\n'}
    BODY=${out%$'\n'*}
}

expect() { # description expected-status
    if [[ "$STATUS" == "$2" ]]; then
        PASS=$((PASS + 1)); printf '  PASS  %-42s %s\n' "$1" "$STATUS"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL  %-42s got %s, expected %s: %s\n' "$1" "$STATUS" "$2" "$BODY"
    fi
}

echo "Testing ${BASE_URL}"

call GET /health
expect "health check" 200

call GET "/customers?limit=5"
expect "list customers" 200

call GET "/customers?limit=500"
expect "list with invalid limit" 400

call POST /customers "{\"name\":\"POC Test\",\"email\":\"${EMAIL}\",\"phone\":\"+1-201-555-0199\"}"
expect "create customer" 201
ID=$(sed -n 's/.*"id":\([0-9]*\).*/\1/p' <<<"$BODY")
echo "        created id=${ID:-?}"

call GET "/customers/${ID}"
expect "read created customer" 200

call PUT "/customers/${ID}" "{\"name\":\"POC Test Updated\",\"email\":\"${EMAIL}\",\"phone\":null}"
expect "update customer" 200
grep -q '"name":"POC Test Updated"' <<<"$BODY" || { FAIL=$((FAIL + 1)); echo "  FAIL  update not reflected: $BODY"; }

call POST /customers "{\"name\":\"Duplicate\",\"email\":\"${EMAIL}\"}"
expect "duplicate email rejected" 409

call POST /customers '{"name":"","email":"not-an-email"}'
expect "invalid body rejected" 400

call DELETE "/customers/${ID}"
expect "delete customer" 204

call GET "/customers/${ID}"
expect "read deleted customer" 404

call DELETE "/customers/${ID}"
expect "delete missing customer" 404

echo "Result: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
