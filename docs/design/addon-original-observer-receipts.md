# Original request observer receipts

The original host request journal now retains observer registration and
completion intents independently of its execution/commit phase. A receipt has
one first observer wall time, a canonical object payload and a digest of the
complete pair. Unknown/duplicate fields, non-finite or negative time and changed
payload/digest are refused. Integer and float wire forms normalize through the
same canonical codec; a lossy time conversion is refused.

Each registration/completion progresses from Unobserved to Pending to
Acknowledged. The intent precedes any registry effect. An acknowledgement names
the exact complete receipt digest; it is a trusted host fact whose registry
validation belongs to the original domain owner. It is not fabricated by this
pure fold. A fresh repeated intent or ACK is invalid; the consumer reuses an
existing state without appending. A lost ACK can use the existing Owner.advance
expected-record protocol to acknowledge the already stored next tail without
writing. Unconfirmed and cancellation still require a fresh original reload.

A completion can be retained before registration delivery is acknowledged, so
an observer failure cannot erase a confirmed domain result. Completion ACK
requires the original registration ACK. A new completion intent requires an
original Finished, Conflicted or Rejected fact (also valid through the refused
parent's Subdividing/Subdivided link phases). Judged, pending and uncertain
commits cannot acquire a completed domain observation. All observer events
preserve execution phase, and ordinary execution events preserve both receipts.
The parent's refusal receipt remains the parent's; a child has its own request.

The generic module depends on neither Curator nor Runs. Its opaque canonical
payload does not certify domain meaning, a successful effect or registry
durability. The [Curator typed codec and preparation port](workspace-curator-observer-receipts.md)
bind original input/outcome/slot/basic usage to the strict capture and actual
phase/judgment. Registry delivery/ACK still require their own fresh validation
and comparison port; the generic payload is not authority for either.
First observer wall time is not provider start time or measured execution
latency. Wall-clock rollback is preserved rather than inventing a duration or
making a time-based authority decision.

This unit deliberately adds persistence, not registry delivery or scheduling.
The existing Runs.register_running and mark_completed can replace existing
terminal evidence. A consumer must not blindly replay either call. The next
registry reconcile port needs comparison under the existing mutation lock,
full available payloads, explicit uncertainty and unchanged-terminal ACK-only
handling. Replay's synthesized server_restarted terminal needs an explicit
provenance-aware correction policy for durable owners. A matching code string
alone must never authorize overwriting another producer's terminal.
Historically acknowledged receipts stay acknowledged after bounded registry
retention evicts a row; eviction must not repopulate all old runs.

Four new real-Store scenario sources cover restart with both receipts pending
while the domain finishes, lost ACK without changing journal bytes/identity,
refusal/successor history and nonterminal completion rejection, and malformed
receipt/history refusal through public Owner.load/advance. They do not invoke a
registry or prove actual registry failure/replay, model/provider execution,
production owner cutover, Off lifecycle, installation or UI behavior. Parser
checks and independent source review are separate from compiled execution.
