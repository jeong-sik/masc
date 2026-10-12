# Authenticated Child snapshot reads

The operator read surface uses the existing token-bound `CanAdmin` permission
on both HTTP/1 and HTTP/2. It captures the authenticated server workspace once;
query parameters cannot select a different workspace. Reads never start a
provider, create a missing store, repair history, or settle a Root or Task.

`GET /api/v1/keepers/:name/child-content/receivers` fully audits discovered stores.
`GET /api/v1/keepers/:name/child-content/hints` returns unchecked metadata/tail
hints. Neither endpoint accepts query fields. A hint cannot certify historical
payload integrity or clear a previous audited failure.

`GET /api/v1/keepers/:name/child-content/records` requires the original
`receiver_generation`, `session_id`, and `client_uuid`. Optional `store_id` and
`after_sequence` must occur together. Query members are closed and single valued;
sequence spelling is canonical decimal within the shared JSON-safe integer
contract. Opaque invocation values use URI query encoding, retaining their exact
bytes. No UUID spelling, current turn, roster, timestamp or Task origin grants
Child attribution.

Missing storage returns 404, invalid scope/query returns 400, a conflicting
incarnation/cursor returns 409, and unavailable or corrupt storage returns 503.
Closed public error codes omit internal paths, exception details and bodies.
Successful records are full-audited READONLY suffixes with a store incarnation
receipt. Consumers decode the closed envelope and then validate it against the
exact requested ticket and cursor; a refusal cannot become an empty success.
The response applies one current redaction snapshot to human body/model leaves
without changing correlations, optional absence, evidence or typed refusal.

Provider completeness and liveness remain unknown. Collector-local persistence
failure history is unavailable to this read surface. Empty discovery, a valid
suffix and an unchecked hint cannot prove that all events were received or
stored. Store sequence and local append time do not order Child against Root.

TUI consumption, matching installed binaries, real provider observations and
visible terminal verification are separate follow-up work. The authored H1/H2
authorization and actual Driver-to-store-to-HTTP fixtures are not execution
evidence until run.
