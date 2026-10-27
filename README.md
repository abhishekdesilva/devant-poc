# POC 3 — Masking PII in application logs

## Why this is needed
This complements any PII-masking guardrail already configured at the AI
Gateway level (which masks PII in LLM prompts/responses) by masking PII your
*own service code* writes to logs — raw emails, card numbers, SSNs, phone numbers — before they
land on stdout, get scraped by Fluent Bit, and end up in OpenSearch/whatever
log aggregator you're shipping to.

## Two layers of masking
1. **Pattern-based** (`maskPii`) — regexes for common PII shapes, applied to
   free-text log messages.
2. **Field-name-based** (`maskSensitiveFields`) — structured key/value pairs
   (e.g. `log:printInfo("...", email = ...)`) are redacted outright when the
   key name matches a known-sensitive list, which is more reliable than
   pattern-matching the value.

## Run it
```bash
bal run .
```

## Test it
```bash
curl -X POST http://localhost:9092/booking/guests \
  -H "Content-Type: application/json" \
  -d '{"bookingId":"BK-1001","email":"alice@example.com","phone":"415-555-0134","cardNumber":"4111 1111 1111 1111"}'
```

Console output will show the structured `email`/`cardNumber` fields as
`***REDACTED***` and the free-text line's email/phone substrings replaced
with redaction markers, instead of the raw values.

## Extending this
- Add more regexes (passport numbers, national ID formats) as needed for
  your region/dataset.
- If you want this centralized rather than per-service, the equivalent guard
  belongs in a Devant-level log processor or Fluent Bit filter so every
  service gets it without importing this module individually — but doing it
  in-process (as here) means unmasked PII never leaves the process at all,
  which is the stronger guarantee.
