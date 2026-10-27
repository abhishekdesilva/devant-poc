// Payloads exchanged with API callers. Column names are mapped to camelCase
// in the SELECT statements, so these records bind directly to query results.

public type Customer record {|
    int id;
    string name;
    string email;
    string? phone;
    string createdAt;
    string updatedAt;
|};

// POST /customers body.
public type NewCustomer record {|
    string name;
    string email;
    string? phone = ();
|};

// PUT /customers/{id} body. Replaces all updatable fields.
public type CustomerUpdate record {|
    string name;
    string email;
    string? phone = ();
|};

public type ErrorBody record {|
    string message;
|};

public type Health record {|
    string status;
    string database;
|};
