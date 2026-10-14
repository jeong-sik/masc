# Prepare and run exact inline Skill children

The source Skill detail views in Dashboard and TUI show retained async result
handoffs and later action facts alongside the original activation. Inline result
and manifest-reference delivery are distinct. The detail counts physical action
occurrences separately from causal links: one SDK invocation connected to two
handoffs remains one action with both links and observation clocks. SDK returned,
SDK errored and native started are distinct facts; native start carries no
completion verdict. Original and receiving turns/runtimes remain visible.
This display implementation needs installed runtime/UI verification separately.

`Keeper_composition_nested.compile` expands an exact, turn-frozen inline Skill
into the existing typed plan. The source `keeper_composition_prepare` schema now
accepts this node alternative for task-specific inline drafts. Prepare freezes
the original recipe, flattened plan, exact child references, normalized arguments,
leaf/export mappings and tool contracts in one owned immutable manifest. Run
recompiles the recipe against its current frozen surface and compares all recorded
provenance before dispatch. Compilation is never activation. This source change
does not update an installed server or its Skill catalog.

The compiler consumes the same closed outer request grammar as ordinary plans.
A node can name one complete pinned inventory reference and fixed arguments:

```json
{
  "id": "prior-evidence",
  "skill_reference": {
    "identity": {
      "source_id": "project-agents",
      "package_id": "prior-art",
      "name": "prior-art"
    },
    "content_revision": "<exact revision returned by the frozen inventory>"
  },
  "args": {"query": "composition"},
  "after": ["earlier-node"]
}
```

Use the actual reference and parameter schema from the frozen capability surface.
The example revision is a placeholder; it is not an accepted reference. Names,
source precedence and a globally valid catalog entry do not grant this Keeper
permission. The exact reference must be model-visible and active on its turn
surface. Changing the content revision is a refusal, without a name-based fallback
or a source-file reread.

Arguments pass the same schema validator as a direct named composition call before
parameter substitution. The compiler checks required fields, types, enums and
extra fields. This API admits fixed arguments only. Feeding upstream output into
a child parameter requires a runtime contract barrier before any child leaf runs;
that separate integration is pending.

Call `keeper_composition_prepare` with `execution: "inline"` or `"async"`, the ordinary outer
`nodes`, `exports` and matching `branch_failure_policy`, and exact child nodes of
the form above. Pass the returned `draft.sha256` to `keeper_composition_run`.
Preparation records no child activation. Nested drafts currently omit `skill`
publication metadata: publishing only their flattened plan would discard child
identities. Named recursive catalog recipes still require their own grammar.
An async parent freezes the original trace, turn, selected runtime, snapshot and
exact Task provenance into its immutable run evidence before worker admission.
Children activate only when a ready leaf reaches dispatch. Continuation restores
existing child admissions and their first activation time, while the physical
worker retains its own execution context. Original Task references are resolved
against the current authoritative published snapshot; current profile denial or
changed exact revisions still refuse execution.
Every public resume, including a completed run, checks the original child
activation before accepting a successor. The worker checks it again before
reusing results. A pre-effect leaf failure does not prove that child admission
was absent. If a waiting successor stops before dispatch, the original wait
remains recoverable only through unchanged journal nodes, matching canonical
job IDs and exact predecessor terminal evidence.

A child output is its declared named export. `/profile` selects export `profile`;
`/document/items/0` selects within export `document`. RFC 6901 escaping applies to
export names too. The compiler maps the export to its exact leaf producer and
revalidates the combined pointer against that producer's schema. Whole-child root
output and undeclared exports are explicit errors.

Every dependency on a child, including a reference to its exported output, waits
on all its leaves. A failing sibling therefore blocks a downstream consumer even
when the selected producer succeeded. Under `continue_independent`, unrelated
branches still run and successful selected exports remain available with the
aggregate failure. Child and parent failure policies must agree in this first
flat-plan compiler; the compiler refuses disagreements instead of changing them.

Expanded IDs encode complete string paths as canonical JSON arrays. Both ordinary
parent IDs and child IDs are renamed, so an arbitrary user ID that resembles a
child path cannot collide. Each compiled call retains its exact reference, bound
arguments and source-to-expanded leaf mapping for later durable evidence.

Async children are refused as `async_child_requires_suspension`. An async request
receipt is not a child result. Connecting that child requires durable suspension,
completion correlation and resumption, rather than flattening a worker as a normal
inline leaf. Expanded leaves admit static read-only ordinary Tool contracts and
the isolated owned-job launch producer with its Serial durable ownership.
General resource-aware effect admission remains a separate implementation unit.

The focused `test_keeper_composition_nested` scenarios check repeated child
references, escaped IDs and export names, parameter contracts, unavailable exact
references, expansion cycles and whole-child failure with retained independent
results, public prepare/run through the ordinary Keeper handler, owned frozen
drafts, actual dispatch admission and parent receipt delivery. Parser checks do
not establish types or execution. Record an actual suite run and head before
claiming these scenarios pass; model latency and installed behavior remain
separate evidence.

The owned-job suite also contains a public nested async-parent scenario with an
actual published inline child that launches, waits and reads complete stdout.
It changes the current Task/runtime, refuses fresh continuation intake with
corrupt or missing original activation, then restores that exact authority and
uses a fresh supervisor to finish the original child. Receipts distinguish
prepare-through-saved-wait, fresh recovery pulse, backend calls before/after
durable output and the original activation/create/start counts. The Docker CLI
is synthetic; executing this scenario does not prove real Docker, a physical
server restart, actual model delivery or a preparation-latency improvement.
An additional scenario replaces activation authority inside actual durable
broker acceptance, then runs the production worker. The worker must return the
original job wait without exports; restoring that authority must let a fresh
supervisor resume the same child and occurrences. This tests the accepted worker
boundary separately from pre-acceptance refusal.

## Nested invocation and delivery evidence

The activation journal has a distinct `nested_composition` invocation carrying
an immutable scope: the exact enclosing `parent_tool_use_id`, UUIDv7
`composition_run_id`, and the source node alias. It keeps the child's own unique
`skill_tool_use_id`, source identity/revision, turn, runtime and origin. Recording
this invocation at dispatch admission is separate from preparing a draft. A child
that never reaches dispatch admission has no activation.

`Keeper_skill_activation_recorder.record_nested_composition` supplies this journal
boundary. Public inline run invokes it immediately before a child's first ready
leaf handler, after dependency and input validation. A per-run mutex shares that
durable admission across concurrent sibling leaves. Missing recorder authority or
failed journal admission refuses the leaf before its Tool effect; independently
ready branches still follow the plan's failure policy. The direct journal feature
scenario alone does not prove leaf dispatch or model latency. Parent scopes reject
blank parent IDs, empty aliases, invalid run
IDs and using the parent ID as the child invocation ID. Reusing a child ID with
changed parent/run/alias is an invocation collision.

A child result is carried by its enclosing Tool result. The later actual provider
request or official-client handoff therefore delivers that child's activation by
matching its exact parent's receipt, in the same Keeper turn scope and under the
existing delivery-order and conflict rules. Two children of one parent retain two
identities and share the observed parent result digest. A receipt under a child ID,
a different parent, or another Keeper turn does not mark the child delivered.
Durable readback preserves both the nested scope and the delivery chain. The web
API readers decode this variant explicitly so one valid nested row cannot make the
whole activation panel unavailable; its label retains child and parent identity.

Public results expose `nested_scopes` with each exact prepared scope, actual
admission identity or rejection, own mapped node dispositions and selected child
exports. `not_started`, `admission_rejected`, `completed`, `failed`, `deferred` and
`partially_settled` are distinct. A child whose dependency failed has no activation.
An available export does not imply the child or parent completed successfully.
The full execution artifact preserves this provenance and every raw leaf result;
the pre-dispatch run artifact retains the original public invocation and all
prepared mappings. Original Task attribution comes from the canonical turn
recorder and survives the parent's result delivery.

Async child activation scopes retain the logical parent
`composition-result:<original run ID>` across request successors. The initial
submission receipt acknowledges acceptance. A later status lookup has its own
actual ToolResult ID; that transport ID is never rewritten into the logical
parent ID.

The status producer now binds a completed prepared result to its original
canonical request, read-only execution journal and sealed run recorder. It
compares every original source coordinate, both artifacts and the actual status
manifest and actual current or historical request membership in the journal
before retaining the full SDK invocation. The status payload and durable manifest
include that invocation's ID, turn, schedule and completion contract. An old
result cannot impersonate a later lookup with identical terminal request data.
A later occurrence may reuse its ID; a failed or ineligible new lookup removes
that ID's prior slot, including missing requests, manifest failures and SDK
validation failures before the handler runs. A different tool using that ID also
removes its previous status binding. The provider observer
stages the actual trailing ToolResults, captures their producer occurrence, and emits correlation only after the
matching successful response. A new turn or runtime attempt clears pending
delivery. The official-client observer consumes its actual result-content
callback with an exact invocation match. Later slot replacement cannot change a
previously staged result. Both retain the physical turn/runtime separately from the original
recorder. They re-read original authority before emitting correlation; unavailable
authority, unbound IDs or different payloads do not acquire a result receipt.

An inline result and a transmitted manifest reference are distinct observations.
The reference receipt hashes the actual marker bytes, and does not claim that a
locally fetched body reached the provider. Repeated status lookups retain their
actual transport IDs and SDK occurrences, including valid ID reuse. An unstaged
historical result that no longer has a current producer binding is not observed.
After a correlated handoff, the observer restores the sealed run's exact original
admitted children and appends an `async_result_delivered` fact to that original
session's canonical Skill event log. The original activation and its Task,
runtime, snapshot and first activation time stay intact. Each child carries the
SHA-256 of its entire original admission frame; both transactional append and
event/projection replay compare that frame before accepting the handoff. A
changed or unavailable original ledger refuses the write with a structured log.
It does not dispatch another worker or create a substitute activation.

`masc.skill-activations/v7` exposes these facts as `async_result_deliveries`, with
separate original/physical turn references, status SDK occurrence, receiving
runtime, canonical request, raw transport receipt, presentation and child frame
digests. Re-observing an identical physical handoff retains its first durable
clock. Distinct physical lookups keep distinct facts. Summary delivery counts
count each child once per boundary kind; runtime histograms count each child once
per receiving runtime. Manifest references remain observable without increasing
inline body-delivery counts. Neither delivery form creates a later action.

The Python measurement reader validates the same original frame digests and
canonical revision as the server. The Dashboard preserves typed digests and validates occurrence shape and scope
membership. Its async Tools fetch additionally verifies causal delivery digests
and the original frames referenced by action facts with portable SHA-256. It does not
authenticate the complete server ledger revision; write authority stays in the
canonical transaction.

The owned-job feature scenario now continues its public prepare/run and fresh
supervisor recovery through a real status tool invocation, raw provider-wire
staging and the official-result observer. It covers failed requests, unrelated
responses, unbound/changed content, exact references, ID reuse across SDK turns
and planned occurrences, old inline/reference content before staging, copied
context without journal membership, absent/malformed requests, actual SDK
validation and reuse by another tool, and missing original run authority.
It checks that no backend operation or child
activation is recreated and emits a separate status-to-correlated-response
measurement. A run of that fixture proves its synthetic transport scope, not an
external provider response, real Docker or installed-runtime behavior. Record the
actual head and run before claiming the new scenarios pass.


## Actions after an async result

An actual inline handoff grants a receiving attempt causal handles for the
original children. These handles retain the original trace and delivery digest;
they never replace the original Task, runtime, snapshot or activation clock.
SDK `PreToolUse` captures the handles without recording execution. Only the
matching `PostToolUse` records the actual handler result as `sdk_result`.
`handler_returned` means the SDK handler returned an `Ok` value; it does not infer
business success from its text. `handler_errored` preserves typed recoverability
and error class. Byte counts and hashes describe returned text or error text,
not attachments. Validation refusals do not create action facts. The following
Execution failure callback does not count an already recorded handler error again.

Official native callbacks currently observe a start, so their fact is explicitly
`native_started`, with the official counter and native identity. They do not
establish completion, exit status or an SDK turn offset. Sibling official-client
results accumulate in the same physical attempt. A provider response establishes
one handoff boundary for all of its staged results. Actual turn/attempt resets
revoke active and pending authority. Publication after durable I/O rechecks the
captured attempt/handoff identity; an old write or failure cannot reactivate or
clear a newer attempt, even if it selects the same runtime id.

The same canonical Skill log appends `async_action_observed`; v7 projections
require `async_actions`. Append, event replay and projection decoding all verify
the referenced inline delivery, receiving physical context and original child
frames. SDK occurrences compare their own counter to the receiving SDK boundary;
native counters stay independent. Repeated facts retain their first clock. A
changed name or result for the same physical occurrence is refused, including
across sibling delivery links. Multiple identical links stay visible while the
child summary counts that occurrence once. A marker reference grants no inline
body authority. Unavailable canonical authority clears only the affected current
observation state and leaves Tool execution running.

The owned-job scenario exercises actual SDK success/error/validation callbacks,
ID reuse, official native starts, duplicate and contradictory facts, sibling
receipts, corrupt-ledger recovery and a real canonical lock around an in-flight
attempt reset. It retains the original child activation and checks zero backend
redispatch after the result. Record an actual run/head before calling these cases
passed. Named async children, dynamic child input, general resource admission,
installed runtime/UI and matched whole-task timings remain
separate work.

### Retained Skill detail

`/api/v1/skills/evidence` uses `masc.skill-evidence/v6`. Each selected activation
requires `async_result_deliveries` and `async_actions`, including explicit empty
arrays when that validated activation has no such observations. Discovery reads
them from the same canonical ledger as the original activation. Receiving-result
and action clocks do not change latest-activation selection or timestamp ties.
An unreadable or changed ledger remains a typed coverage gap.

The selected view joins actions through stored delivery identities and keeps
the original child's frame digest, turn, run and parent identity. A shared
handoff retains sibling frame digests; the selected-detail decoder validates
the requested child's frame and does not claim to authenticate absent sibling
frames. Other children do not contribute their own handoffs or actions to this
selection. Dashboard and TUI data readers require both arrays, reject changed
original frames and contradictory or unbound action links, and retain SDK
results and native starts as distinct facts. No new store or runtime gate is
introduced; the canonical ledger remains write authority.

The owned async scenario continues actual SDK follow-on callbacks through fresh
retained discovery and the production detail projection. Its elapsed read and
projection time is a separate measurement from prepare/run latency or an HTTP
network request. Source and an actual run/head establish this data path; installed
UI display and matched whole-task performance still require separate evidence.
