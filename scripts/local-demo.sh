#!/usr/bin/env bash
# Runs POC 7 locally: the three targets, the caller and a mock OAuth server,
# then checks each path. There is no Devant gateway locally, so this shows how
# the caller authenticates (none / OAuth / API key); Devant adds the gateway
# checks on top.
#
#   ./scripts/local-demo.sh            # build, run, check, stop
#   KEEP_RUNNING=1 ./scripts/local-demo.sh   # leave everything running for manual calls
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGS="${ROOT}/scripts/.logs"
mkdir -p "$LOGS"
PIDS=()

cleanup() {
    [[ "${KEEP_RUNNING:-}" == "1" ]] && { echo "Left running (PIDs: ${PIDS[*]}). Stop with: kill ${PIDS[*]}"; return; }
    kill "${PIDS[@]}" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT

wait_for() { # url
    for _ in $(seq 1 60); do curl -s -o /dev/null "$1" && return 0; sleep 0.5; done
    echo "Timed out waiting for $1"; exit 1
}

for dir in project1/order-service project2/customer-service project2/inventory-service project1/caller-integration; do
    echo "Building ${dir}"
    (cd "${ROOT}/${dir}" && bal build >"${LOGS}/build-$(basename "$dir").log" 2>&1) || {
        echo "Build failed, see ${LOGS}/build-$(basename "$dir").log"; exit 1; }
done

node "${ROOT}/tools/mock-oauth-server.js" >"${LOGS}/mock-oauth.log" 2>&1 & PIDS+=($!)
java -jar "${ROOT}/project1/order-service/target/bin/order_service.jar" >"${LOGS}/order.log" 2>&1 & PIDS+=($!)
java -jar "${ROOT}/project2/customer-service/target/bin/customer_service.jar" >"${LOGS}/customer.log" 2>&1 & PIDS+=($!)
java -jar "${ROOT}/project2/inventory-service/target/bin/inventory_service.jar" >"${LOGS}/inventory.log" 2>&1 & PIDS+=($!)
wait_for http://localhost:9443/oauth2/jwks
wait_for http://localhost:9091/orders/1
wait_for http://localhost:9092/customers/1
wait_for http://localhost:9093/inventory/1

# Wire the caller the way Devant connections would, through environment variables:
#   order-service:     URL only                  (Project visibility)
#   customer-service:  URL + OAuth credentials   (Organization visibility)
#   inventory-service: URL + API key             (Public visibility)
ORDER_SERVICE_URL=http://localhost:9091 \
CUSTOMER_SERVICE_URL=http://localhost:9092 \
CUSTOMER_TOKEN_URL=http://localhost:9443/oauth2/token \
CUSTOMER_CLIENT_ID=test-client \
CUSTOMER_CLIENT_SECRET=test-secret \
INVENTORY_SERVICE_URL=http://localhost:9093 \
INVENTORY_API_KEY=local-demo-key \
java -jar "${ROOT}/project1/caller-integration/target/bin/caller_integration.jar" >"${LOGS}/caller.log" 2>&1 & PIDS+=($!)
wait_for http://localhost:9090/demo/orders/1

echo
echo "GET /demo/all?id=42"
curl -s "http://localhost:9090/demo/all?id=42" | node -e '
let input = "";
process.stdin.on("data", d => input += d).on("end", () => {
    const results = JSON.parse(input);
    const expected = {
        "order-service":     {auth: "none",                      authorizationHeader: false, apiKeyHeader: false},
        "customer-service":  {auth: "oauth2-client-credentials", authorizationHeader: true,  apiKeyHeader: false},
        "inventory-service": {auth: "api-key",                   authorizationHeader: false, apiKeyHeader: true},
    };
    let failed = 0;
    for (const r of results) {
        const e = expected[r.target];
        const caller = (r.response && r.response.caller) || {};
        const ok = r.ok && r.status === 200 && r.auth === e.auth &&
            caller.authorizationHeader === e.authorizationHeader && caller.apiKeyHeader === e.apiKeyHeader;
        if (!ok) failed++;
        console.log(`  ${ok ? "PASS" : "FAIL"}  ${r.target.padEnd(18)} ${r.visibility.padEnd(13)} auth=${r.auth.padEnd(26)} ` +
            `status=${r.status} ${r.latencyMs}ms  received: Authorization=${caller.authorizationHeader} API-key=${caller.apiKeyHeader}`);
    }
    console.log(failed ? `Result: ${failed} failed` : "Result: all paths passed");
    process.exitCode = failed ? 1 : 0;
});'
STATUS=$?

echo
echo "Target down (inventory-service stopped):"
kill "${PIDS[3]}" 2>/dev/null; sleep 1
curl -s http://localhost:9090/demo/inventory/42; echo
exit $STATUS
