# Keeper chat wire boundaries

`Keeper_chat_events` owns normalized events and its exhaustive `redact_content`
map owns content redaction for both live and journal serialization. `Keeper_chat_event_log` encodes the
journal, and `Server_keeper_chat_agui_projection` produces AG-UI for live delivery
and replay. Projection preserves protocol field names, closed enums and exact
correlation identities. Secret redaction applies to human content leaves through
typed serializers; arbitrary tool argument JSON retains its separate recursive
key/value redaction boundary. Do not apply that arbitrary JSON redactor to a
serialized protocol envelope.

`Runtime_json_integer.of_json` defines the numeric decoding boundary for native
progress, native completion, model content identity, and journal and live TUI occurrence/sequence.
JSON numeric values must be integral and exactly representable by both OCaml int
and ECMAScript Number: the intersection with `[-(2^53-1), 2^53-1]`.
`1`, `1.0` and `1e0` represent the same value. This is numeric representation,
not a limit on runtime work. Domain codecs retain positive byte counts,
nonnegative elapsed seconds/indices, and signed exit codes. Dashboard uses
`Number.isSafeInteger` for the corresponding fields.

Journal envelopes reject duplicate or unknown fields and non-finite timestamps.
Event discriminants reject duplicate top-level fields. Native events and their
occurrences reject unknown fields and present malformed identities, preserving
the distinction between absent provider identity and corrupt metadata.

Provider elapsed seconds describe a report, independently of local observation
time. TUI Tools details preserve elapsed, message and output-byte observations
together, including a decreasing provider elapsed report. Native end, provider
response stop, model content end and Keeper turn completion remain separate facts.
None of these metadata belong in authored conversation text.

`test_tui_model_response_phase_pty.py` drives a real TUI under a controlled SSE
fixture and records full original ANSI frames. Screenshot replay must retain
source SHA, executable hash, terminal dimensions and the original ANSI; compare
xterm cells to the recorded PTY before accepting a screenshot. Fixture evidence
does not establish behavior of installed or live-provider binaries.

A poisoned provider scope publishes ended activity for each model block it actually observed. The typed protocol diagnostic remains visible, body bytes remain intact, and later events from that scope are rejected. This does not publish a provider MessageStop or complete the Keeper turn. A cut scope (incomplete or repeating response) retains activity tracking because its legal content/terminal sequence is still admitted.

History append identity and turn ownership are distinct. Operation delivery keys retain their operation journal identity. Workspace broadcast, Fusion and approval delivery keys require an explicit turn_ref or autonomous marker to claim a turn; otherwise the row stays unowned. The structural append identity remains intact, including when separate delivery namespaces reuse the same request string. A passive broadcast is not evidence that a Keeper consumed that message.
