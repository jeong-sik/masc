# Closed native task HTTP read views

`Keeper_native_task_read` is the shared OCaml representation of the existing
`native-tasks/records` and `native-tasks/receivers` HTTP response envelopes. The
HTTP adapter serializes these views, and callers decode the same contract.
Endpoint paths, CanAdmin authorization, query grammar, status mappings and the
SQLite v2 journal contract remain unchanged.

## Read authority

A decoded view contains observations, receiver references, cursor receipts and
process health diagnostics. It cannot construct a journal publication, a private
journal record, a bound native call or an input ticket. The server projects
private journal reads into distinct public records in one direction. The
projection applies the current supplied redactor through
`Runtime_native_tasks.redact`: only permitted metadata leaves change. Task DTO
serialization and decoding reuse `Runtime_native_tasks.to_json/of_json`.
Opaque identity bytes, signed provider numbers and optional flags are retained.

The authenticated connection supplies workspace authority. Receiver scope is
Keeper, generation and session. A cursor is the existing SQLite store
incarnation and committed `after_sequence`; it is not a task ID, liveness
receipt or independently authenticated capability. Public data cannot select a
filesystem root or grant write authority.

## Structural and request validation

`of_json` accepts only the existing closed schemas and variants. Every object
rejects duplicate, missing and unknown fields. Host sequence numbers must be
nonnegative JSON-safe integers; records start above zero. Times must be finite.
Task observations retain the DTO's own validation. Rows must match the envelope
scope, have distinct event UUIDs and contiguous increasing sequence numbers,
and end at the shared validation/next-cursor tail. Discovery keeps each audited
or failed entry and rejects duplicate receiver references.

A structurally valid response may describe a suffix whose first sequence is
unknown to the decoder. The consumer must then call `records_of_response` with
its actual request. Beginning requires sequence 1; an exact cursor requires
`after_sequence + 1`, the same store incarnation and the same requested scope.
An empty suffix is accepted only when the request already reaches the returned
tail. Constructible request cursors are validated again at this boundary.
`receivers_of_response` similarly checks the requested Keeper. There is no
silent cursor reset, skipped prefix, guessed receiver or failure-to-empty
fallback.

Callers first branch on `Failure` to retain the typed service error and health.
The success matchers reject failures or the other endpoint as
`Unexpected_response`. Missing stores, invalid scope/query, stale or foreign
cursors, corruption and I/O failures remain distinct wire codes. A successful
empty discovery or caught-up read remains a successful value.

## Diagnostics and evidence limits

Health preserves the existing process-only or unavailable coverage. The
required nullable `receiver` and `error` issue leaves remain explicit JSON null
when absent. Cleanup warnings retain their operation/status without private
exception details. Error health is required except for the existing early
invalid-Keeper rejection. Provider completeness, historical persistence failure
coverage and terminal absence remain explicitly unknown. Neither a receipt nor
empty diagnostics establish that a provider or receiver is live or complete.

Authored fixtures connect actual H1/H2 authenticated routes to the decoder, and
actual private runtime callback bindings to `Api.response`, JSON string
serialization/parsing, decoding and request matching. Negative fixtures cover
foreign scope/incarnation, missing prefix, unordered/gapped sequence, duplicate
UUID/receiver, unsafe numbers, nonfinite time, closed shapes and nullable
health. These fixtures have not been executed in this coding session. Parser
checks establish syntax only. This unit adds no TUI rows, task event pump,
Dashboard union, authentication redesign or SQLite leaf security proof.
