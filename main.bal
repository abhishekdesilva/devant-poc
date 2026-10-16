import ballerina/http;

listener http:Listener httpDefaultListener = http:getDefaultListener();

service /devant\-service on httpDefaultListener {

    resource function post echo(@http:Payload EchoRequest echoRequest) returns EchoResponse {
        return {message: echoRequest.message};
    }
}
