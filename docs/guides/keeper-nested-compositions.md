# Prepare and run exact inline Skill children

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

Async child result receipts use a stable `composition-result:<original run ID>`
parent identity across request successors. The original submission receipt only
acknowledges acceptance and cannot mark these child results delivered. The public
fixture separately exercises the completed result receipt and original ledger
facts. Wiring that receipt into actual provider requests and official-client
handoffs, and the full nested owned-job wait/fresh-supervisor scenario, remain
separate execution evidence to obtain; source binding alone does not prove them.
