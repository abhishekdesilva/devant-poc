import ballerina/http;
import ballerina/log;
import ballerina/time;

// Integration 2 (Project2): returns a JSON greeting.
// Endpoint visibility is Organization, so integrations in other projects of the
// same organization can call it through the Devant gateway with credentials.

configurable int port = 9090;

service / on new http:Listener(port) {

    // GET /greeting?name=Provident
    resource function get greeting(string name = "World") returns json {
        log:printInfo("greeting request received", name = name);
        return {
            message: string `Hello, ${name}!`,
            servedBy: "integration2",
            project: "Project2",
            timestamp: time:utcToString(time:utcNow())
        };
    }
}
