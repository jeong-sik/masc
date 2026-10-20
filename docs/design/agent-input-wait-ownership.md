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

Checkpoint v12 persists `pending_input` explicitly, including null when no wait
is outstanding. Full encode/decode, message-encoding memo headers and checkpoint
deltas carry the same proof. Agent resume and clone preserve it. The public
checkpoint captures messages and pending ownership under the same Agent lock;
MASC's optional sidecar uses that public capture too. An independent restored
Agent owns its copy; cross-process intake/one-shot admission remains the host
continuation owner's responsibility.

This changes the exact current checkpoint schema: older versions are refused,
and v12 requires the pending-input field. It adds no conversion, purge, reset or
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

## Stored HTTP observation

The existing admin `GET /api/v1/keepers/:name/checkpoints` response includes
`input_wait_observation`, with schema `masc.keeper.input-wait.observation.v1`
and source `canonical_checkpoint`. One strict exact-snapshot read supplies
the current summary, the full pending proof and its checkpoint reference
`{trace_id, turn_count, sha256}`. The SHA-256 names the bytes actually read,
without JSON re-encoding. Replacing a request in the same turn changes that
reference. It is an observation at that read, not a promise that storage
has remained unchanged until a later response.

`stored_pending` includes the original run ID and canonical request; a readable
checkpoint with no wait is `stored_none`, with a non-null reference and null
pending input. Missing, corrupt, unsupported, identity-mismatched or unreadable
sources produce `unavailable` with a typed error, null reference and null input.
History remains a separate summary and never supplies a replacement current
wait. This explicit inventory route adds no fleet-wide scan or refresh loop.

An exact persisted checkpoint proves its stored observation, not the authority
of every possible live or retained continuation. In particular, retained native
Owner state can differ after an uncertain canonical write. Owner-serialized
response admission/CAS, live/retained reconciliation, SSE invalidation and TUI
projection remain subsequent layers. Clients must not turn this stored
observation or historical feed replay into permission to submit a response.
