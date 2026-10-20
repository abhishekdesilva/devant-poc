// Payloads exchanged with callers.

public type Customer record {|
    int id;
    string name;
    string email;
    string createdAt;
|};

// POST /customers body.
public type NewCustomer record {|
    string name;
    string email;
|};

// An email as recorded in the outbox (mock mode) or as sent (smtp mode).
public type EmailMessage record {|
    string id;
    string to;
    string subject;
    string htmlBody;
    string template;
    string mode;
    string status;            // SENT or FAILED
    string sentAt;
    string[] unresolvedPlaceholders;
    string? 'error = ();
|};

// The email part of the POST /customers response.
public type EmailResult record {|
    string id;
    string status;
    string mode;
    string? 'error = ();
|};

public type CustomerCreated record {|
    Customer customer;
    EmailResult email;
|};

public type ErrorBody record {|
    string message;
|};
