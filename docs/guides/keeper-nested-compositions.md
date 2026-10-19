# Prepare and run exact Skill children

The source Skill detail views in Dashboard and TUI show retained async result
handoffs and later action facts alongside the original activation. Inline result
and manifest-reference delivery are distinct. The detail counts physical action
occurrences separately from causal links: one SDK invocation connected to two
handoffs remains one action with both links and observation clocks. SDK returned,
SDK errored and native started are distinct facts; native start carries no
completion verdict. Original and receiving turns/runtimes remain visible.
This display implementation needs installed runtime/UI verification separately.

Inline Read/Edit/Write recipes and exact inline children can bind producer-owned file
resources after upstream inputs resolve, including pure child argument validation.
Shared-mount Overwrite/Append can retain an existing ancestor when parent
directories are missing; creation stays at the original authorized Write boundary.
See [recipe file execution](keeper-recipe-file-execution.md) for independent leaf
execution, conflict order and call-owned cleanup. Async file effects require their
own durable replay contract.

`Keeper_composition_nested.compile` expands an exact, turn-frozen inline Skill
into the existing typed plan and lowers an async Skill into native submission
and canonical result nodes. An async child requires an async parent. The source `keeper_composition_prepare` schema now
accepts this node alternative for task-specific drafts. Prepare freezes
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

Fixed arguments pass the direct named-call schema validator during preparation.
An inline or async child can instead declare an explicit `input` template using the ordinary
literal/output/object/array grammar. Supply exactly one of `args` or `input`:

```json
"input": {
  "kind": "object",
  "fields": [{
    "name": "query",
    "value": {"kind": "output", "node": "earlier-node", "pointer": "/content"}
  }]
}
```

The private inline argument node or native async submission node resolves upstream
values and checks the frozen Skill parameter schema before child activation or broker entry. Missing fields, types,
enums and extra fields fail that parent branch without activating the child.
The opaque original parent occurrence supplies the resolved input for both the
child's parameter binding and its immutable Nested producer source. Continuation
reuses those arguments and the accepted source; it does not select current values
or reread a Skill document. Repeated exact references retain separate aliases,
inputs and child sources.

An inline child uses a compiler-owned pure argument node, followed by its expanded
leaves. Each parameter reads the validated argument's exact output field. The
argument node needs no async submission or execution journal, so an inline parent
can consume an earlier Tool output directly. With an async parent, the canonical
journal retains the original resolved arguments, occurrence IDs and child activation
through fresh continuation. The argument node is part of the child's membership
and immutable evidence; its complete namespace path cannot collide with a leaf or
ordinary parent ID. Invalid arguments dispatch no child leaf, while independent
branches retain the parent's declared failure policy.

The declared plan and contracts are frozen even when arguments depend on output.
Parameter substitution is pure and shared with ordinary named Skill calls.
Validation of the resulting leaf inputs remains part of child execution: a
parameter that satisfies the Skill schema can still fail a narrower leaf schema.
Private operand evidence retains declared parameter leaves, while the public
request grammar continues to reject `param` and compiler metadata.

The native compiler has distinct child-submission and child-result
operands. Submission is effectful and Serial, with an opaque acknowledgement;
result observation is readonly and Concurrent, with the bound child's exact
named-export schema. Schemas are frozen per child, so two result nodes using
the same tool name cannot borrow each other's output contract. Owned plan
evidence retains the exact child reference, argument template, declared plan and
recursive contracts. Copying that private evidence into a public request does
not create a compiler capability.

An async parent can prepare and run an async child through the same exact
reference grammar. Its original Nested activation seals the child producer;
submission records an immutable parent-occurrence-to-child-source join before
broker entry. The protected acceptance callback commits the real child membership
and child journal binding before retaining acceptance in the parent journal.
The result node reads only that accepted binding through the canonical result
reader. Pending children release the parent worker; whole-child failures and
cancellations stay failures, and successful named exports are validated against
the frozen result schema before any consumer can use them.

A Lost parent whose child acceptance was committed can recover that original
acknowledgement with its original occurrence IDs, even before its first result
wait. This does not authorize replay of an unproven effectful tool. A failed
acceptance callback remains distinct from a later worker-publication failure;
both retain their real evidence. Missing, changed or copied child authority
cannot create replacement acceptance. These are source guarantees until an
exact-head execution receipt proves the selected scenario; installed runtime,
visible UI and whole-task speedup remain separate evidence.

Continuation refusal does not by itself establish a terminal run failure.
Missing or unreadable source, ledger, profile or Task-selection authority stays
recoverable. A stale intake cannot change the winning owner or an immutable
Waiting predecessor. An explicit current Tool denial can become a failure only
after the exact frozen plan, including its ordinary and nested contracts, has
been revalidated. A removed ordinary producer also requires a complete,
readable scan of its original Skill source; catalog projection or selection
absence alone is insufficient. Nested withholding remains recoverable.

These proven refusals use a new broker successor with the original source and
Journal owner CAS. The worker rechecks the original authority before publishing;
unavailable evidence leaves recoverable Lost work. Completion callbacks, summaries,
result readers and the outbox require actual current/prior Journal membership for
journal-owned requests, including Done and persistence-failed physical attempts.
A losing CAS attempt retains its physical rejection without announcing a logical
run failure. The outbox is prepared before acceptance, and membership validation
prevents a rejected intake from delivering a false terminal notification.

An owned worker retains `Lost` when its execution journal rejects
plan admission or a node attempt, or when settlement/observation cannot commit.
Those infrastructure failures do not establish a whole-child failure. The
canonical child reader's actual terminal failure still settles the parent as
failed. Fault scenarios cover the original activation before and after restore,
the frozen draft before executor admission, and the parent journal before
submission settlement and result-node lookup. Each restores the original bytes
and resumes the same accepted child; these fixtures require execution evidence.
The canonical reader distinguishes a valid observation (including an actual
failed child) from unavailable observation/publication in its typed result.
Native result nodes retain the latter without inferring meaning from an error
class or message. The producer also retains its actual committed child acceptance
before projecting its acknowledgement, so an acknowledgement-manifest failure
does not erase the first parent's accepted child. Separate real store faults
exercise acknowledgement and successful child-result publication, while a
canonical failed-child scenario verifies that actual failure remains terminal.
The executor retains every actual node cause in planned order. Its first cause
still controls the displayed error; physical interruption examines the complete
cause set. A lower pending sibling therefore cannot hide a higher publication or
settlement failure. The process-loss fixture includes an independently pending
lower node alongside the original native child, including faults after a higher
node's tool completed but before its observation committed.

Call `keeper_composition_prepare` with `execution: "inline"` or `"async"`, the ordinary outer
`nodes`, `exports` and matching `branch_failure_policy`, and exact child nodes of
the form above. Pass the returned `draft.sha256` to `keeper_composition_run`.
For immediate execution, pass that complete prepare input as
`keeper_composition_run.recipe`. It freezes the same child references and
records the original invocation before the existing executor admits children.
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

An admitted child retains the actual activation receipt returned by its original
recorder or exact ledger lookup. Result evidence includes that receipt and its
immutable frame digest. Result delivery compares it with the original ledger,
including the first activation clock; a matching invocation ID alone is
insufficient. Later delivery and action observations do not change that frame.
The native receipt lookup neither records a new activation nor grants broker
admission. Original parent-to-child submission recovery still requires the
producer-owned intent and parent journal transition described below.

Losing the first worker before it records any result wait does not prove that
its effects were absent. An unfinished effectful attempt, an unknown or
post-effect failure, or a defer without a valid producer-owned result wait
retains its pending marker and reports `replay_not_proven`. Maintenance does
not schedule a replacement, and public manual resume refuses before accepting
another request. The original Task, occurrences and retained results stay in
the same journal. Declared read-only unfinished work still permits the existing
manual resume; this refusal does not add a retry budget or a new runtime setting.
Native child acknowledgement recovery additionally requires its immutable
submission intent, committed parent acceptance and exact canonical child
membership. Other unproven effectful attempts retain the refusal above.

A child output is its declared named export. `/profile` selects export `profile`;
`/document/items/0` selects within export `document`. RFC 6901 escaping applies to
export names too. The compiler maps the export to its exact leaf producer and
revalidates the combined pointer against that producer's schema. Whole-child root
output and undeclared exports are explicit errors. Those rejections include
`available_exports`, taken from that exact admitted child, with each public name
and its canonical escaped pointer. Copy the pointer with the rejection's child
`node_id` into an output template or final export; internal leaf fields are not
additional child exports. An empty list means the child declares none. Repairing
the pointer still goes through the original schema and whole-child validation.

Every dependency on an inline child, including a reference to its exported output,
waits on all its leaves. An async child uses its canonical whole-result barrier.
A failing sibling therefore blocks a downstream consumer even
when the selected producer succeeded. Under `continue_independent`, unrelated
branches still run and successful selected exports remain available with the
aggregate failure. Child and parent failure policies must agree in this first
flat-plan compiler; the compiler refuses disagreements instead of changing them.

Expanded IDs encode complete string paths as canonical JSON arrays. Both ordinary
parent IDs and child IDs are renamed, so an arbitrary user ID that resembles a
child path cannot collide. Each compiled call retains its exact reference, bound
arguments and source-to-expanded leaf mapping for later durable evidence.

Inline parents refuse async children as `async_child_requires_suspension`.
Async parents use the native submission and result operands described above;
an async request receipt is not a child result. Within async parents, named Skills
and expanded inline leaves admit static read-only ordinary Tool contracts, owned
Ask questions (`masc_ask`), and the isolated
owned-job launch producer with its Serial durable ownership. An async child can
start its own job, wait for its original result and export its complete output.
Fresh continuation reuses the settled launch instead of dispatching it again.
The producer journal also retains the original answer-input observation frame
through fresh continuation. Logical node IDs remain stable, while fresh Tool
result rechecks carry distinct physical invocation IDs. See
[Ask answer follow-up](keeper-ask-answer-recovery.md#preserve-the-answer-through-async-composition-continuation)
for source ownership, unknown evidence and the Before/After scenario scope.
An unfinished launch without proven replay authority remains refused as above.
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

`masc.skill-activations/v8` exposes these facts as `async_result_deliveries`, with
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
passed. Dynamic inline child input, general resource admission,
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

## Continuation failure classification

Original child activation checks return either admitted authority or held
original authority. Missing, unreadable or conflicting receipts cannot prove
that the logical run failed or that a new child may start. Journal ownership
changes, unproven replay and failed observation commits retain the original
run rather than finalizing a competing owner or discarding unknown effects.

A producer-proven pre-effect policy or workflow rejection is different: the
worker publishes its failed result instead of turning that rejection into a
new Lost attempt. All parallel failure causes participate; one unavailable
accepted child or uncertain authority still holds the run. Original child
source reads remain runtime failures when the immutable evidence cannot be
read, rather than being relabeled as permanent policy decisions.

The automatic continuation controller retains a process-local hold for the
exact physical owner that reports unavailable original authority. Later pulses
still discover canonical state but do not submit another attempt for that same
owner. Repair the original evidence and explicitly resume the run with its
existing `resume_run_id`; a successor owner is eligible for normal intake. A
new controller can also retry through all original admission checks. This hold
is a scheduling hint, not durable effect or completion authority: the physical
request may remain Lost, and unknown effects never become a logical failure
merely to stop automatic retries.

Original authority can also become unavailable between canonical discovery and
worker admission. The same held-owner notification applies when the original
draft, activation receipt or original task Skill selection cannot be read.
Repairing the evidence preserves the original Waiting request; it does not
silently remove a controller hold or admit a new worker on the next tick.
Explicit original-run resume still performs every current authority check.
