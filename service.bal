import ballerina/http;

// A tiny service that demonstrates the masking wrapper in use, so you can
// curl it and watch the console output instead of only reading unit tests.
service /booking on new http:Listener(9092) {

    resource function post guests(BookingRequest req) returns json {
        // BAD (commented out): would leak PII straight into logs/observability.
        // log:printInfo("booking created for " + req.email + " card " + req.cardNumber);

        // GOOD: free text is scrubbed, and structured fields named like PII
        // are redacted outright regardless of their value.
        logInfo("booking created for customer", {
            email: req.email,
            cardNumber: req.cardNumber,
            bookingId: req.bookingId
        });

        logInfo(string `contact number on file: ${req.phone}, reachable at ${req.email}`);

        return {status: "confirmed", bookingId: req.bookingId};
    }
}

type BookingRequest record {|
    string bookingId;
    string email;
    string phone;
    string cardNumber;
|};
