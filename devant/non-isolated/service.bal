import ballerina/http;
import ballerina/jballerina.java;
import ballerina/lang.runtime;
import ballerina/log;

// POC 10: NON-ISOLATED variant. Identical to ../isolated/service.bal except for
// how the shared request counter is declared and accessed (marked "DIFFERENCE").
//
//   GET /cpu?iterations=N  CPU-bound work: N steps of integer arithmetic, standing in
//                          for computation such as calculations, parsing or encoding.
//   GET /io?ms=N           Waits N ms without using a thread, like calling another service.
//   GET /stats             Variant, CPU cores the integration can use, and request counts.
//
// Every request also increments a shared, in-memory counter. Here the counter is
// a plain module-level variable. The compiler can't prove it's safe, so it reports
// "concurrent calls will not be made to this method" and the listener runs this
// service's requests one at a time on a single thread.

const VARIANT = "non-isolated";

// DIFFERENCE: plain module-level variable, no isolated, no lock.
map<int> requestCounts = {};

// Port 9090 in Devant (see .choreo/component.yaml); override locally with -Cport=<port>.
configurable int port = 9090;

final int cpus = availableProcessors(getRuntime());

service / on new http:Listener(port) {

    function init() {
        log:printInfo("isolation demo started", variant = VARIANT, cpus = cpus);
    }

    resource function get cpu(int iterations = DEFAULT_ITERATIONS) returns WorkResult|http:BadRequest {
        if iterations < 1 || iterations > MAX_ITERATIONS {
            return <http:BadRequest>{body: {message: string `iterations must be between 1 and ${MAX_ITERATIONS}`}};
        }
        int result = compute(iterations);
        return {variant: VARIANT, work: "cpu", iterations, result, requestNumber: countRequest("cpu")};
    }

    resource function get io(int ms = DEFAULT_WAIT_MS) returns WorkResult|http:BadRequest {
        if ms < 0 || ms > MAX_WAIT_MS {
            return <http:BadRequest>{body: {message: string `ms must be between 0 and ${MAX_WAIT_MS}`}};
        }
        runtime:sleep(<decimal>ms / 1000);
        return {variant: VARIANT, work: "io", waitedMs: ms, requestNumber: countRequest("io")};
    }

    resource function get stats() returns Stats {
        return {variant: VARIANT, cpus, requestCounts: snapshot()};
    }
}

// DIFFERENCE: the counter is read and updated directly.
function countRequest(string kind) returns int {
    int count = (requestCounts[kind] ?: 0) + 1;
    requestCounts[kind] = count;
    return count;
}

// DIFFERENCE: read directly, without a lock.
function snapshot() returns map<int> {
    return requestCounts.clone();
}

// Pure computation: no allocation, no locks, no library calls, so the time is
// spent on the CPU alone.
isolated function compute(int iterations) returns int {
    int x = 0;
    foreach int i in 0 ..< iterations {
        x = (x * 31 + i) % 1000003;
    }
    return x;
}

isolated function getRuntime() returns handle = @java:Method {
    name: "getRuntime",
    'class: "java.lang.Runtime"
} external;

isolated function availableProcessors(handle jvmRuntime) returns int = @java:Method {
    name: "availableProcessors",
    'class: "java.lang.Runtime"
} external;
