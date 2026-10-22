# Agent input wait ownership

Reference: the [official MCP SDK elicitation contract](https://ts.sdk.modelcontextprotocol.io/v2/servers/elicitation)
represents user action separately from submitted content. The distinction
supports explicit settlement here; this Agent API retains its own closed
Answer/Declined/Timeout vocabulary and does not claim MCP wire compatibility.

An input pause belongs to its original invocation and canonical request. An
agent name or question is display data; it cannot identify a pending request.
`Agent.pending_input` returns that owned `(run_id, request)` value. The run ID
is the same started invocation carried in `AgentInputRequired.task_id`, not
the separate raw-trace run ID in an outcome envelope. Invocation identities
exist with or without an event-bus subscriber. Request IDs use the existing
fresh-ID source rather than agent name, turn and timestamp.

`Agent.provide_input` takes this proof, checks both IDs under the Agent's state
lock, uses the owner's canonical question, appends an Answer message if needed,
and consumes the pending wait in the same mutation. Declined and Timeout are
explicit settlements without synthetic messages. An old, foreign or repeated
response returns a typed refusal and leaves the current request and messages
unchanged. A Timeout response is not automatic wall-clock expiry.

Publishing Started is not an accepted resume: input/callback validation can
still refuse the call. The shared input stage consumes only its captured
pending proof after the before-turn decision accepts continuation. This covers
sync, streaming, low-level `run_turn_stream` and Advanced continuation, including
a later failure and intermediate checkpoint. A replacement that arrived during
a callback is not consumed by the earlier captured identity. A new input pause
is installed before publishing its lifecycle outcome. Failed pre-resume calls
leave the old pending wait intact. Low-level streaming turns publish their own
Started and outcome rather than bypassing the invocation owner.

Checkpoint v13 persists `pending_input` explicitly, including null when no wait
is outstanding. Full encode/decode, message-encoding memo headers and checkpoint
deltas carry the same proof. Agent resume and clone preserve it. The public
checkpoint captures messages and pending ownership under the same Agent lock;
MASC's optional sidecar uses that public capture too. An independent restored
Agent owns its copy; cross-process intake/one-shot admission remains the host
continuation owner's responsibility.

This changes the exact current checkpoint schema: older versions are refused,
and v13 requires both pending-input ownership and explicit missing-usage
response coverage. It adds no conversion, purge, reset or
installation step. Existing checkpoint-version mismatch behavior must be
considered before deployment; source review does not prove a live runtime has
adopted this format.

This first layer repairs the producer/continuation boundary for #38005. It does
not implement the host's current-state HTTP snapshot, snapshot/SSE revision
reconciliation, request-bound settlement relay, or Acting's standing run state.
Those consumers must read the owned continuation and retain server incarnation,
original invocation and request identity. Historical feed events alone cannot
prove a current wait after a replay gap. Keeper quiet/member state stays
independent. #38005 remains open until those paths and their behavior are proven.

## Input transition persistence

The next layer connects installation, accepted-resume consumption and explicit
Answer/Declined/Timeout settlement to the existing configured checkpoint sink.
`After_input_wait_changed` carries the candidate messages and exact pending
proof together. The Agent state lock covers the owner check, sink invocation
and mutation. Only a successful sink result installs that candidate in memory;
without a sink the transition remains in-memory. Sinks must not re-enter the
same Agent's checkpoint or mutating APIs while serving this boundary.

The lifecycle wrapper binds its started invocation in fiber-local context.
The pipeline installs the wait inside that execution scope, before native
terminal disposition. This boundary precedes InputRequired publication and parameter or
provider work after accepted resume. A sink failure becomes a typed run failure
rather than publishing a durable input pause. Rejected validation and replaced
request identities do not consume the owner's stored wait. Explicit responses
return `Input_not_current` separately from `Input_checkpoint_failed`; the latter
does not claim that external storage was untouched. A sink can commit and then
report uncertainty, so the host must reread/reconcile instead of treating the
error as a retry permission. This layer adds no cross-process response endpoint.

The direct native adapter advances its retained Owner before invoking the
optional canonical sink. Until a subsequent ordinary checkpoint succeeds,
terminal disposition preserves that Owner's actual retained reference rather
than advancing from an older Agent snapshot. This also covers a failed
canonical acknowledgement or a later checkpoint-journal append exception;
terminal handling does not retry the uncertain write or resurrect its prior
pending request. Canonical and retained checkpoint observations remain distinct.

Keeper's sink rejects `Stale_noop` for an input transition: leaving another
canonical checkpoint in place is not a successful write of this owner. A first
BeforeTurn input pause can have no AfterTurn ordinal. Keeper finalization now
preserves that absence rather than refusing the pause or inventing a provider
turn; it emits no per-AfterTurn cost event in that case and projects a null
ordinal. Other successful stop kinds still require their original ordinal.

## Owned HTTP observation

The existing admin `GET /api/v1/keepers/:name/checkpoints` response includes
`input_wait_observation`, with schema `masc.keeper.input-wait.observation.v2`
and source `retained_input_owner`. One current Owner mailbox read captures
its trace, original session root and durable input relation. The route first
checks that this trace matches the inventory metadata, then loads and validates
the exact retained artifact named by the Owner reference. Its
`{trace_id, turn_count, sha256}` names those retained bytes. The canonical file
and history remain independent diagnostic inventory; they never supply input
state when owned evidence is unavailable.

| Status | Meaning | Checkpoint reference | Pending input |
| --- | --- | --- | --- |
| `unobserved` | Fresh-history Owner has no input observation for its current trace | null | null |
| `owned_pending` | Exact owned retained checkpoint contains a pending request | exact owned reference | full original run/request/question/schema |
| `owned_none` | Exact owned retained checkpoint contains no pending request | exact owned reference | null |
| `unavailable` | Current Owner, original trace relation, prior input history or retained artifact cannot be verified | null | null |

The response also includes `trace_id` for successful observations and null for
unavailable ones. Typed error categories distinguish `owner_unavailable`,
`trace_changed`, `prior_input_unavailable` and `retained_unavailable`; retained
errors preserve a cause and detail. No failure invents a fresh state or borrows
another question. Replacing a request or consuming it within the same turn
changes the exact owned reference. A stale pending canonical cannot resurrect
consumed input, and a missing/corrupt canonical cannot hide an owned wait.

This is a read-time snapshot. The Owner can advance after the mailbox read;
retained evidence can then become unavailable. Neither successful observation
nor reconnect grants response or continuation authority. Reads remain possible
through the original Owner's draining lookup and create no Owner. The explicit
inventory request adds no fleet-wide scan, refresh loop, cache or inferred expiry.

The source fixtures use the actual HTTP handler, Owner input publisher and
retained store, and an actual Core decline candidate to observe consumption.
They cover same-turn replacement, stale/missing/corrupt canonical state,
Owner reinstall, missing/corrupt/hash-mismatched retained evidence, unavailable
Owner/prior history and metadata trace drift. Source typing, executing these
fixtures, and product acceptance remain separate evidence.

## Durable direct-operation waiting

`Keeper_semantic_execution.Input_wait` records the complete canonical pending
request and exact owned checkpoint reference in the existing `Recovering`
representation. It retains that checkpoint and is distinct from an ordinary
checkpoint, runtime retry or Gate wait. Generic resume and successful settlement
cannot consume it. Its request timeout never becomes a timer or expiry policy.

`Keeper_chat_operation_store.defer_direct_input_wait` admits this state only
for the original running direct operation and execution digest. Within one
SQLite transaction it checks the current input-owner reference and the original
native call's matching checkpoint and settled `Retire` disposition, records
the wait, acknowledges the native receipt and queues the same operation. The
original input and admission order survive. Active or unknown native effects,
stale references/digests and conflicting canonical questions refuse. A queued
duplicate is idempotent only when the complete waiting value still matches.

Claim, priority, ordinary resume and restart paths leave an unresolved wait
blocked regardless of elapsed time. Independent queued inputs remain claimable.
Explicit cancellation settles the original wait while preserving the separate
global input-owner fact. Uncertain commit acknowledgement remains an error;
readback exposes the actual committed state without converting that error into
acceptance or releasing retained-file deletion authority.

This Store API is a journal boundary, not proof that a physical retained
checkpoint contains the request. Its caller must validate the original child,
trace, session root and exact retained payload before admission. The SQLite
fixtures exercise real journal transactions, restart, identity refusal,
independent work, cancellation and commit faults; their opaque checkpoint
references do not establish filesystem availability or runtime integration.

## Direct turn and Owner admission

The direct turn now calls `Keeper_owner_registry.defer_direct_input_wait` for
its typed `Runtime_agent.InputRequired` result. It supplies the original
operation identity, never a question or pending-request value. The existing
Owner requires the inherited current chat child and its running operation,
then reads the current trace's input relation under its original session root.
The owned reference must equal the original retired native call's checkpoint.

The Owner loads that exact retained snapshot with the same
`load_retained_exact_snapshot` used by the host observation. It checks the
original operation's repetition scope and derives the complete pending value
from those bytes before committing the journal wait. Missing, corrupt or changed
retained bytes, consumed input and foreign scope refuse. Canonical/history
cannot substitute. The lifecycle invocation ID in `pending.run_id` differs
from the durable native locator's execution run ID; their binding is the actual
child-published checkpoint and native receipt, not equality between those IDs.

Child completion and the HTTP operation-pending selector recognize the input
wait as a committed nonterminal continuation. It supplies no ordinary resume
reference. Delivery or transcript failure after deferral cannot turn the queued
wait into terminal operation success or failure. Existing visible question
projection is retained independently of this durable operation lifetime.

The six additional Owner fixtures use real inherited children, SQLite and
retained files. They cover independent work, actual Owner reopen and cancellation,
no inherited child, consumed input, missing/corrupt/hash-mismatched retained
evidence despite readable canonical state, and foreign operation scope. They do
not execute a provider or the complete direct-turn/HTTP/UI path.

Dedicated input-wait surface classification, durable autonomous waiting,
Owner-serialized response admission/CAS and continuation, live/retained
reconciliation, SSE invalidation and persistent TUI projection remain required.
Caller and response integration must ship together before this stack can become
ready. All #38005 layers remain Draft; this contract does not authorize
installation, merge or whole-issue completion.
