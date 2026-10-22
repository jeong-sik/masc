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
lock, uses the owner's canonical question, appends one User response observation,
and consumes the pending wait in the same mutation. Answer keeps its JSON
rendering. Declined and Timeout produce distinct explicit observations for the
canonical question without inventing an answer. The synchronous callback and
restored Agent use the same mandatory-message Core formatter; all three response
kinds reach model-input preparation and durable restored history. This does not
guarantee the model will avoid asking again. Request schemas are preserved but
Core currently does not validate Answer JSON against them; no schema-validation
guarantee is made here. An old, foreign or repeated response returns a typed
refusal and leaves the current request and messages unchanged. A Timeout response
reports the caller's explicit settlement; Core adds no timer or wall-clock expiry.

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
independent. Acceptance for #38005 remains incomplete until those paths and their behavior
are proven, independently of the issue tracker lifecycle.

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
ready. PR Draft/Ready state does not certify this contract or authorize
installation, merge or whole-issue completion.

## Explicit direct response admission

The existing administrative `POST /api/v1/keepers/:name/checkpoints` accepts
`action: "respond_input"`. Its body carries the original `operation_id`, exact
`checkpoint_ref` (`trace_id`, `turn_count`, `sha256`), complete `pending_input`
from the owned observation, and one closed `response` value:

```json
{"kind":"answer","value":"the explicit answer"}
```

Or use `{"kind":"declined"}` or `{"kind":"timeout"}`. Timeout is an explicit
response, never elapsed-time expiry. Missing, duplicate or extra protocol fields,
invalid references and unknown response kinds are rejected before Owner lookup.
A valid request cannot create a missing Owner or infer a waiting operation.
The existing route's administrative authentication remains required.

The Registry submits one exclusive maintenance attempt to the existing Owner.
Busy returns without response effects. Before effects, the unpaused original
maintenance child captures the exact queued wait, operation digest, current
input relation, trace and original session root. The caller's complete wait
must match that original authority; matching IDs with a different question do
not pass. Before a direct wait is published, the same original executing child
supplies its visible InputRequired request to the Owner. The Owner derives the
pending request from its exact retained checkpoint and compares every request
field there, before the SQLite deferral transaction. A mismatch leaves the
original operation running, its native retirement receipt unacknowledged and
its input relation unchanged, without publishing a wait. A successful comparison
does not substitute caller fields for the stored canonical question. Canonical
files are not a fallback for this comparison. This is distinct from delivery:
a later transport failure still preserves an already admitted wait.

Physical installation rechecks exact retained bytes, original operation scope,
complete pending, and canonical history. The canonical must retain the original
messages and agree on all nonhistory fields. Only the capture timestamp and an
independently validated derived session `message_count` can differ. Context,
working-context, MCP, tools, parameters, usage or turn drift requires explicit
reconciliation; a same request ID is no permission to overwrite either source.
Missing/corrupt/diverged canonical is likewise refused in this layer. These
remaining reconciliation cases must be handled before the whole feature ships.

The public Core response owner derives the canonical question and consumes the
request in a temporary Agent without provider dispatch. Physical installation
updates an existing validated derived message count to the consumed history
length, freezes the complete candidate, retains those exact bytes and installs
canonical with an exact predecessor CAS. A sealed receipt belongs to that same
original Owner authority/maintenance child. File retention/CAS and SQLite are
separate commits; a partial file install is evidence requiring reconciliation,
not acceptance or automatic retry permission.

The Owner consumes that receipt only while the same unpaused maintenance child
and trace remain current. One SQLite transaction compares the original queued
wait/digest and input predecessor, publishes the consumed checkpoint and converts
that wait to the same operation's checkpoint continuation. Generic claim stays
blocked until this response transition. Afterwards the existing checkpoint
continuation restores the original scope and consumes its exact reference without
appending the original prompt again. Acceptance is not continuation completion.
Duplicates refuse without consuming a different request. An uncertain journal
acknowledgement stays Error even when the transaction actually committed; reread
the actual original operation/input before reconciling, never blindly resubmit.

Response errors retain their typed stage across Owner and Registry. An Owner
failure keeps its original cause; a lifecycle failure alone does not prove that
no physical effects occurred. Installation failure preserves the original file
outcome, including uncertainty. If confirmed retention and canonical installation
return different references, both references remain an installation mismatch.
After a sealed physical receipt, any journal error remains commit-unconfirmed
with the exact installed checkpoint and original Owner error. It is never
converted to an input-rejection string.

The administrative HTTP boundary maps these failures explicitly:

| Outcome | HTTP status |
| --- | --- |
| Malformed request | 400 |
| Busy, stale/duplicate proof, missing Keeper in an available inventory | 409 |
| Unavailable inventory, stopping/closed Owner or missing server network context | 503 |
| Retained/canonical input unavailable, internal store failure, unconfirmed/mismatched installation or journal acknowledgement | 500 |

A server failure is neither acceptance nor evidence that no bytes changed. The
client must read the actual original input/operation before reconciliation. No
automatic retry, new operation, proof substitution or cleanup authority follows
from the status code. These error distinctions do not implement the still-required
physical/journal divergence recovery.

Actual source scenarios cover three explicit Owner responses and same-operation
continuation, stale question and busy/duplicate refusal, Store atomicity and
pre/post-commit faults, physical stale nonhistory refusal and valid derived
count, and real HTTP/Registry/Owner/SQLite admission plus snapshot consumption, duplicate
refusal and malformed-proof/missing-Owner boundaries. The positive HTTP scenario
prepares its original wait in the journal and uses no provider. These are not
provider/full direct-turn/UI execution proof. Executing them remains separate.

Official-client elicitation is currently unsupported: `prepare_turn` refuses
`ElicitInput`; adapter successes produce Completed/scheduling yields, and Codex
MCP elicitation cancels with Host_input_unavailable. Its lifecycle InputRequired
consumer is not a producer. The actual direct Agent Core InputRequired path
installs the native binding/terminal receipt required by waiting admission.
Enabling official-client input later requires its own continuation authority.
The existing unified success receipt precedes durable wait admission; a later
admission error does not rewrite that earlier run receipt into operation success.

This feature remains incomplete. Autonomous
waiting, dedicated input-wait classification,
canonical/live/retained divergence reconciliation, snapshot/SSE invalidation and
persistent/reconnected Acting/TUI are still required for #38005 acceptance.

## Durable direct response intent and checkpoint lifetime

Before canonical mutation, the response protocol needs a journal fact binding
one complete original wait W, validated original source S, frozen consumed
candidate C and typed Answer/Declined/Timeout response. S may extend W's history;
it need not equal W. All references share W's trace, S does not regress W's
turn, and C preserves S's turn while changing both source and wait bytes.
Canonical answer JSON rejects duplicate keys and non-finite values. These
identity checks do not validate a physical transformation or grant installation
or response authority.

`prepare_direct_input_response` records that exact response payload transactionally under
the actual original queued operation, execution digest, complete wait, retired
native state and current input predecessor. The same intent preserves its
revision; a different response/source/candidate/wait cannot replace it. Its
destination can only advance from canonical to operation input as described
below, spending a revision while preserving that complete payload. Recording
it keeps the wait blocked, including claim, priority, generic resume and successful
settlement. An actual commit may survive an uncertain acknowledgement; that
acknowledgement remains an error with no deletion or automatic retry authority.
The reader returns the actual persisted fact, never one inferred from a file.

Semantic retention and startup sweep include S and C while the intent exists.
Ordinary continuation/pending-input selection excludes both: only W remains the
original waiting authority. Reconciliation diagnostics preserve the intent;
resolution must name its exact C, clears it with the original continuation/input
publication, and keeps C live. Confirmed cancellation or failure releases the
intent references while independent global input ownership remains authoritative.
The optional fact is omitted when absent. A present null, malformed/duplicate/
unknown fields, unknown response kind, mismatched wait or incompatible phase is
rejected by the strict journal codec.

The actual direct Owner now captures the original wait and persisted intent
under its exclusive maintenance child. It prepares the Core response and freshly
confirms retention of both S and C, serializes intent confirmation through that
same Owner, then installs canonical under its captured exact predecessor CAS.
Only a sealed receipt for the same authority and complete recorded intent can
resolve the original journal wait. Intent journal errors preserve the prepared
W/S/C fact separately from post-install resolution errors; HTTP classifies their
original typed cause (including storage uncertainty as 500).

After reopening, a fresh Owner/child obtains fresh authority from the original
queued operation/digest/wait. An existing intent admits only its same typed
response. Retained W/S/C, original scope, complete nonhistory data, source history
and exact Core rederivation of C are checked again. Canonical S admits S->C;
canonical C admits C->C through an actual durable rewrite, after the recorded
intent proves that candidate. Missing/corrupt retained evidence is refused
without replacement. Canonical mode also refuses a different canonical source;
operation mode instead uses the retained-only protocol described below. No hash equality or readback by itself
mints a receipt or turns an uncertain acknowledgement into acceptance.

The first journal commit is now intent confirmation, before canonical mutation.
Actual HTTP pre/post-intent commit faults keep canonical W and the original wait;
the committed fact survives an actual Owner close/reopen and admits only the
same response. Separate scenarios install real S/C, inject a real SQLite
resolution fault, reopen the journal in a fresh Owner and reconcile consumed C;
a committed uncertain resolution is observed as an existing continuation and
refused as a duplicate. These prepared resolution-fault scenarios exercise actual
files, SQLite and fresh Owner HTTP recovery, not fault injection inside the
Owner's final resolve invocation. The physical fixture also tests stale canonical
CAS, corrupt retained C and fresh receipt authority.

Full original-invocation resumption after independent Producer publication of
newer global input G still needs typed lineage reconciliation preserving its
history, context and other pending request; refusing G is not that recovery. The canonical history-extension
fixture keeps global input W and must not be cited as that independent integration.
R1 remains incomplete. Autonomous waiting, dedicated classification,
snapshot/SSE and persistent/reconnected Acting/TUI also remain mandatory. This
unfinished implementation does not authorize installation or merge.

## Shared Core explicit settlement observations (R2)

The shared formatter always returns one User message. The live callback appends
it before parameter preparation, while the owned restored path saves it together
with consumed pending ownership before in-memory publication. Decline and timeout
are distinct model-visible facts, never fabricated Answer JSON. Their typed
responses remain distinct in events, intent storage, comparison and admission.

The integrated Core scenario exercises all three responses through the callback
and through actual checkpoint save/close/reopen, then compares their real
`Agent_turn.prepare_turn` effective input before provider dispatch. It also
supplies a forged display question to the restored API, which must use the owned
canonical question. Keeper Response and original Owner scenarios retain complete
metadata and original prompt history while adding each explicit observation.
These are input preparation and storage checks, not evidence that a provider
changes its behavior or that an installed runtime has adopted this layer.

Independent Producer G reconciliation, autonomous waiting, dedicated outcome and
status consumers, snapshot/SSE invalidation and persistent/reconnected Acting/TUI
remain mandatory for #38005. PR readiness does not authorize installation or merge
of an unfinished feature.


## Independent operation input branch foundation

A different Owner child can publish global input G while the original direct
operation is blocked at W. G can have another question, context and execution
scope. Message-prefix similarity does not authorize merging them. The intended
continuation owns a separate branch C derived by Core from the original full
request, while the independent global input and canonical G stay unchanged.

The semantic record now has an optional `input_branch`, independent of phase.
Its immutable `origin` contains the first exact W and complete pending request;
its current `checkpoint` is the branch's retained input head. Creating a branch
requires the original blocked wait and prepared response intent's exact C.
Resolving also removes the intent and enters `Suspended C` in the same semantic
transition. Consuming that continuation into Running does not remove the branch
pin. Reconciliation also preserves it, including before the next native Bind.
The historical root remains retention evidence, not current pending authority.

A branch input advance compares its exact prior head and the same operation's
active native call at the candidate. Trace identity and nondecreasing turn are
necessary but cannot substitute for the physical producer proof. A second wait
must equal the current branch head. Its next response advances that head while
preserving the first full origin. Attached response resolution cannot consume a
branched wait. Actual terminal settlement releases branch ownership; an unknown
native-effect receipt keeps its own checkpoint evidence. Official-client
continuations cannot carry an Agent Core input branch.

This layer implements semantic transitions, strict persisted JSON and retention
projection only. Its tests start from the actual direct-wait Store fixture, then
exercise Semantic transitions and JSON round trips; no independent G Producer,
physical branch response, SQLite branch commit, Owner recovery, native resume or
canonical-sink isolation is established. The Store/Owner response endpoints keep
their current guards. Follow-up integration must bind this branch through those
actual boundaries before accepting a G-independent response, and must test
another child publishing G with additional history/context and another pending
question, original-operation native resume, later checkpoints and crash/reopen.
Neither this foundation nor an exact G refusal completes R1 or #38005.


## Independent branch response storage primitives

Each response intent now persists a closed `Canonical_input` or
`Operation_input` destination alongside its exact W/S/C and canonicalized
response. Strict intent equality includes that destination. Reconciliation can
only keep the same complete fact or promote Canonical_input to Operation_input
without changing W/S/C/response. An identical preparation is idempotent; a
promotion spends a revision. Neither a different response nor reattaching an
operation branch is admitted. Persisted intents missing this destination are
invalid; no conversion or fallback is provided.

Canonical response installation keeps its existing source CAS and fresh durable
write. An operation response derives from actual retained original W, or the
recorded actual retained S during recovery. It does not borrow canonical G's
history, context, pending request or execution scope. Both S and C are freshly
retained before recording the intent, and the operation installation receipt
comes from a fresh confirmed retention of C. Recorded C must still exist and
validate; rederiving it is not authority to repair missing/corrupt evidence.
A receipt's complete intent and destination remain tied to its captured
physical authority. A former canonical receipt cannot match the promoted
operation intent used by the Owner's final receipt comparison.

The SQLite operation resolution consumes the exact original wait and prepared
candidate into its persistent branch while leaving the global input head G
unchanged. Actual before/after commit uncertainty remains an error, preserves
existing evidence and grants no cleanup or automatic retry authority. Fresh
reads determine which intent destination and branch actually committed.

The physical regression uses an actual different Owner child invoking Producer
prepare/publication to retain G, followed by a canonical save of G. G contains
additional history/context, an independent execution scope and another pending
question. It then exercises fresh operation response and same-C promotion,
actual SQLite resolution faults, physical recovery and close/reopen while
checking canonical G bytes and global G reference. The Store suite separately
checks promotion commit faults, strict destination parsing and the branch pin
through actual SQLite phase consumption.

Public Owner response admission still requires global input W and explicitly
selects Canonical_input. Enabling a branch Accepted response before replacing
the old shared-canonical loader/Producer/sinks would let generic claim dispatch
fail the original invocation. This layer therefore adds the actual physical and
SQLite primitives without activating that unsupported public path. No new
blocked phase or feature flag substitutes for the intended continuation. The
next coherent integration must select the branch at Owner admission and carry
it through retained-only cooperative/runtime/Gate loading, native publication,
all later checkpoint/error/fallback saves and actual original invocation resume.
The primitive tests do not prove that continuation, HTTP branch acceptance,
autonomous input waiting, current-state/SSE reconciliation or the final Acting
behavior. R1 and #38005 remain incomplete.

## Operation branch native publication and retained loaders

An operation branch's native Bind or Checkpoint and branch-head advance now
share one SQLite semantic CAS. The native seed may include admitted setup
context beyond response C; no separately visible native/branch publication
window is required. Branch publication keeps commit uncertainty as Error rather
than turning a later readback into acknowledgement. The global input publication
and retired-history-cut APIs refuse a branched operation.

The original executing Owner child captures an opaque input writer whose
destination comes from its actual running operation and journal branch. It
binds child token, trace, operation and execution digest. Branch input changes
compare both actual native and branch predecessors in the same transaction;
ordinary native progress may have advanced since the writer was captured.
Neither that capture nor branch publication reads or writes global input G.
Generic native receipts for a branch also require the inherited current original
chat child. A foreign, missing or ended child cannot reuse the writer or publish
another operation's native receipt. A later wait validates the branch's exact
retained pending request and retired native receipt instead of substituting G.

Cooperative and runtime retry loaders with a branch load its exact retained
continuation and original operation scope. The branch head must equal the
phase-specific checkpoint and belong to the admitted session. They do not read,
rewrite or append original input to canonical G. Their deferral adapters likewise
read the retained branch. Non-branch continuations keep their existing shared
canonical-history admission.

Source fixtures add actual SQLite pre/post-commit Bind/Checkpoint faults and
reopen comparisons, plus an actual Registry/Owner child that consumes a retained
cooperative admission, binds and advances native receipts, publishes a second
pending input and defers that same original operation. It checks outside-child
publication refusal, exact branch/native references and unchanged independent
G bytes/input through reopen. The fresh response fixture now also invokes the
actual native adapter and Core journal against a loopback provider, as described
below. These changed fixtures have only been parsed locally; their execution and
typing remain unverified at this integration checkpoint.

This is still one unfinished native integration unit. Complete Gate/approval,
ordinary/error/fallback/rejected-response/finalization and actual original
invocation/crash acceptance remain required. Public Owner
response admission retains its exact global-W and Canonical_input restriction
until those paths are connected and tested together. That restriction is not
the intended final recovery behavior. No whole R1/R2/TUI acceptance, installation
or feature merge is claimed by this checkpoint.


## Typed host checkpoint publication (integration work in progress)

A dispatch captures one closed canonical or operation destination from actual
Owner evidence. The operation destination retains a private copy of its latest
confirmed payload and original child writer. Native and host writes fence this
local state before fallible retention, publication or observation; only exact
confirmed success restores it. Errors and exceptions, including cancellation,
leave subsequent reads and writes unconfirmed. Exceptions propagate unchanged.
No failed write is retried or converted to success by reading it back.

Ordinary host changes preserve the entire original message prefix, complete
pending input, turn/trace and repetition snapshot. Explicit replay projection
uses the existing direct-turn policy and also retains every original ordinary
User message and message bearing a ToolUse/ToolResult in order. Incomplete
Assistant cuts reuse the existing exact typed cut. Each proof binds source and
candidate references, checked again against the actual retained artifacts by
the original Owner child. Candidate Context is privately frozen before proof
validation and reference encoding. The existing pure replay and Assistant patch
implementations now live together below Owner so this proof creates no module
cycle and existing consumers keep the same implementation.

The actual Core Retire reference N remains unchanged after host publication H.
For a pending-input wait, Owner proves exact retained N-to-H prefix, complete
pending and repetition preservation. The journal transaction then rechecks
current branch H and same-trace/same-turn Retire N and acknowledges only N as
it queues H. The global path continues requiring the identical input/native
reference. Same turn alone is never physical proof of this relationship.

The source fixture covers cancelled host publication, immutable confirmed
Context, edited-candidate proof refusal, lost response/repetition refusal,
pre-native host admission, actual Owner/Producer publications and separate
Retire N plus host H waiting, preserving independent G. Source parsing and review
are not execution or whole-issue acceptance.

## Native and host destination wiring (integration work in progress)

The direct native binding now requires the same dispatch destination captured
by the original Owner child before continuation loading. Native scope admission,
ordinary checkpoints and pending-input publication fence and confirm that
destination around their actual retained/Owner/Producer writes. An active native
resume publishes the exact retained source rather than its in-memory repetition
reconciliation. Failed publication never replaces its receipt with a later
Agent snapshot during terminal handling.

Branch Gate loading reads retained original and branch checkpoints instead of
canonical G. It enters the exact resolved Gate phase before host admission.
Admission captures the original wait before that transition: retained-source or
host-save errors requeue that wait even though Resuming_gate has no pending Gate
projection. Durable approval truth is reread by reconciliation. The source adds
two actual original-child failure scenarios, checking wait, obligation, requeue,
resolution recovery, reopen and unchanged G. One removes the exact retained file
after destination capture; the other supplies a destination fenced by a cancelled
host save. These cases do not claim successful Gate effect replay.

AgentRun uses the confirmed branch payload before context preparation, routes
approval admission and ordinary checkpoint sinks through its captured destination,
and uses an exact typed witness for incomplete-response history removal. Its
finalizer reads the confirmed latest payload, applies the existing direct replay
projection under a typed proof and records the actual retained artifact path.
Canonical dispatches retain their existing canonical save and replay policy.

The fresh response source fixture now continues stored response C through actual
Native.prepare and Runtime_agent.continue_from_checkpoint. A loopback provider
requests one real tool invocation and then completes; the fixture checks model
input, tool execution, native Retire, branch Context/reference and unchanged G.
It then creates a distinct confirmed host H, authorizes an exact incomplete
Assistant cut and invokes the native adapter again. The second real call must
preserve the settled ToolResult and host metadata, publish matching native and
branch references, execute no second tool effect and leave G unchanged. This
tests the typed cut path; it does not simulate the provider's truncation decision.
It subsequently uses synthetic next-boundary receipts to test another pending
request and host finalization/reopen. Those later synthetic receipts are not
another actual Core invocation. The fixture is source only until executed on
this exact candidate; it does not prove the production AgentRun/finalizer flow
or a crash during the actual invocation.

The retired cut now has a branch-specific Store Bind. It requires Retire with
the host source's trace and turn, compares the exact captured host predecessor
and native observed state, and publishes native plus next branch seed in one
SQLite transaction. Commit uncertainty remains Error; no readback grants an
acknowledgement or file cleanup. Global input is not read or written.

Native authorization starts at the dispatch's confirmed H after validating
retained N-to-H preservation. At publication the original Owner child verifies
its captured predecessor equals the opaque cut source, rereads exact retained
N/H/cut/seed payloads, checks the original operation scope, reconstructs the
N-to-H preservation and H-to-cut-to-seed proof, then invokes that Store Bind.
The returned branch writer names the actual next seed, while the canonical
writer retains its existing exact-cut input relation. Store source regressions
add stale predecessor/native/digest refusal and before/after-commit fault/reopen
cases with distinct N/H and preserved global G.

The actual minimal run [39721832962](https://github.com/jeong-sik/masc/actions/runs/39721832962)
checked out `2e6c249fb7ff0c4b27076a3b975c7e9bfb881b9a`: compilation passed;
42 direct-input Store cases and five native-context cases passed. The physical
response suite ran ten cases, with nine passing and one failing during the
second native dispatch's retired-cut binding. Owner validation runs in a storage
systhread; the host proof copied a private Context with an Eio mutex, whose later
serialization attempted `Cancel.Get_context` outside an Eio fiber. Host proof
copies now use a synchronous mutex; live Agent Context ownership is unchanged.
This repair still needs execution on its new head.

The earlier minimal run [39721391608](https://github.com/jeong-sik/masc/actions/runs/39721391608)
checked out `7a8bedd781306e244cf4767621810f83be30c49f`, ran 121 cases, and
passed 120. Its one failure was an invalid test message: a ToolResult with the
Assistant role. The fixture now uses a valid Assistant ToolUse and Tool
ToolResult pair, checks that both survive final-text suppression, and separately
refuses removal of an open ToolUse. The later retired-cut failure occurred
before this fixture, so it does not establish that this repair passes.

Two additional source scenarios drive an approved and a denied original Gate
through actual native continuation. The approved case uses an explicitly
simulated external web-search read with real grant validation, durable replay
artifact, resolution consumption and checkpoint admission. A second replay must
recover the same output reference with no available simulated network outcomes.
The denied case admits its exact rejection message. Both inspect actual loopback
provider request bodies for every original User and admitted Gate message,
retain the original continuation after a journal reopen and preserve independent
G. The physical response suite now has twelve cases; these two new cases remain
unexecuted. A journal reopen after settled execution is not a crash during an
actual native invocation or evidence for production AgentRun finalization.

Full Gate success/replay, all fallback/error paths, actual invocation crash recovery
and public branch response acceptance remain unverified. The public exact-W
guard therefore remains in place while this coherent integration is unfinished.
Durable autonomous waiting, dedicated waiting outcomes, snapshot/SSE revision and
incarnation reconciliation, and persistent/reconnected Acting/TUI acceptance also
remain part of #38005; none is replaced by this implementation checkpoint.


The subsequent minimal run [39723082826](https://github.com/jeong-sik/masc/actions/runs/39723082826)
checked out `48e31262fd2a5239ea5263e6d0801a5da5ef7789` and passed all 59
cases: direct-input Store 42, physical response 12, and native-context five.
The actual log confirms both Gate success cases, provider input assertions and
durable replay recovery, and completion of the previously failing fresh branch
case. This establishes the scoped repairs and Gate scenarios at that head;
it does not execute the new branch process-restart scenario below.

## Actual original-branch process restart scenario

The native-context restart suite now has a branch mode in addition to its
existing canonical mode. Setup drives an actual Core BeforeTurn input pause,
lets the original Owner derive and defer W, then runs a separate autonomous
Owner child which publishes G through the real Producer. G carries different
history, Context and another complete pending request. Its canonical bytes are
frozen before installing the original operation's response C with the stored
response primitive; public Owner response acceptance remains guarded.

The original child consumes the exact cooperative C admission before native
preparation. Core receives the original declined input, publishes a real Active
native checkpoint containing a ToolUse, then the test calls Unix._exit before
the tool executes. A new process/Eio/Owner lifetime captures the actual retained
operation destination and resumes that Active call. The resumed tool, post-tool
hook and injector must run once; their shared Context updates must reach the
retained final checkpoint. Actual loopback provider input must contain the
original explicit decline and must exclude independent G history. The final
native and branch references must agree before Owner acceptance; only Owner
completion retires the branch. G canonical bytes and its global reference are
checked across publication, process restart, replay and completion.

This scenario uses real native journals, SQLite, response artifacts, process
exit and Owner restart,
with a loopback provider and an in-process tool. It does not yet establish
public response acceptance, production AgentRun/finalizer behavior, a crash
after an unknown external effect, or the remaining autonomous/UI requirements.


The minimal run [39723963986](https://github.com/jeong-sik/masc/actions/runs/39723963986)
checked out `3b97ccd22a20a69988115f4b129cd4c66b87bd9f`, compiled, and passed
all six native-context cases. Its raw log includes the real process cut before
the tool, fresh Owner restart, resumed tool/hook/injector once, exact G byte and
global-reference preservation, and branch retirement after Owner completion.
That is actual evidence for the adapter-level scenario at that head. The shared
fixture extraction and admitted Keeper/AgentRun scenarios below still need
execution on their new head.

## Admitted Keeper/AgentRun branch scenarios (source, not executed)

The physical original-input setup is now shared between the native-context and
real Keeper-ingress suites. Its immutable invocation carries the original
operation ID, source, input, message metadata, runtime and provider. The setup
still uses an actual Core input pause and separate Owner/Producer G publication;
only response C installation uses the stored response primitive. Public Owner
response acceptance remains guarded. Native-context behavior and its actual
process-crash boundary remain covered after extracting this shared fixture.

The real ingress suite adds three branch scenarios through the actual
Keeper_turn.handle_keeper_msg_admitted and AgentRun, with the existing durable
person-note tool and real tool-load, approval and post-result hooks:

- Exit immediately after the target ToolResult commits to the native journal,
  before its checkpoint append. A new Owner lifetime must recover that exact
  result, avoid repeating the note effect, and reach actual AgentRun finalization.
- Exit after the admitted turn and finalizer return, before Owner receipt
  acknowledgement. Restart must retain interruption evidence and refuse
  redispatch of the terminal invocation, while preserving G.
- Exercise the existing known-empty-terminal saved-tool completion path and
  actual finalizer without replaying the durable effect or replacing G.

Each provider request must retain the original explicit decline and exclude
independent G history. Before Owner completion, the latest retained branch must
preserve the native settled ToolResult, original speaker/input and repetition
scope. A strictly decoded actual Checkpoint_saved manifest must link that
retained branch artifact. Canonical G bytes and its global input reference are
checked during provider dispatch and after terminal Owner handling; branch
retirement is checked after that handling. Branch mode is recorded separately
in the executable evidence, rather than conflated with canonical-mode results.

These are unexecuted source scenarios. Passing them would establish their
specified admitted Keeper/AgentRun paths, not every fallback/error path, public
response admission, unknown external-effect recovery, autonomous waiting or
persistent/reconnected Acting/TUI behavior.
