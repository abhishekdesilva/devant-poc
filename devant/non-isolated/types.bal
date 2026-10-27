// Shared with ../non-isolated/types.bal: keep the two files identical.

const int DEFAULT_ITERATIONS = 10000000;
const int MAX_ITERATIONS = 1000000000;
const int DEFAULT_WAIT_MS = 200;
const int MAX_WAIT_MS = 10000;

type WorkResult record {|
    string variant;
    string work;
    int iterations?;
    int result?;
    int waitedMs?;
    int requestNumber;
|};

type Stats record {|
    string variant;
    int cpus;
    map<int> requestCounts;
|};
