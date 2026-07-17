---
rfc: "oas-recursive-execution-masc-integration"
title: "OAS recursive execution integration for Keeper, Fusion, and the dashboard"
status: Draft
created: 2026-07-17
updated: 2026-07-17
author: codex
last_verified: 2026-07-17
source_baseline: masc/main@d5bd126498f88e256c2e5e912d20ae1f7a22baeb
oas_source_baseline: oas/main@fd713eb0cfc4ffa9887a5d4830f497be7263004d
supersedes:
  - masc-oas-bridge-total-llm-dispatch-boundary
  - shared-admission-primitive-knob-binding-policy
superseded_by: null
implementation_prs: []
depends_on:
  - oas/RFC-OAS-029
  - oas/RFC-OAS-037
  - a released agent_sdk surface carrying those contracts
related:
  - docs/OAS-MASC-BOUNDARY.md
  - docs/spec/04-turn-lifecycle.md
  - docs/spec/13-oas-integration.md
  - docs/rfc/RFC-0338-lane-per-keeper-persistence-isolation.md
  - docs/rfc/RFC-0341-keeper-lifecycle-projection-ssot.md
  - docs/rfc/RFC-masc-oas-bridge-total-llm-dispatch-boundary.md
  - docs/rfc/RFC-shared-admission-primitive-knob-binding-policy.md
  - https://github.com/jeong-sik/masc/issues/22654
---

# OAS recursive execution integration for Keeper, Fusion, and the dashboard

## §0 Decision and current claim

MASC consumes OAS recursive execution as an embedding application. OAS remains
generic and imports no MASC module, type, route, runtime configuration, or
product policy.

This document is a **target integration contract**, not a feature-complete
claim. Product completion requires a released OAS public surface, MASC vertical
slices, deterministic crash/recovery tests, and the generated conformance
evidence in §13. A documentation-only change satisfies none of those
gates.

The core decision is deliberately small:

1. MASC adapts one finite Keeper action and one finite Fusion action into OAS
   executable bindings.
2. Those bindings are exposed as ordinary `Agent_sdk.Tool.t` values.
3. Agent-as-Tool, heterogeneous arrays, awaited arrays, and durable asynchronous
   arrays use OAS public adapters directly.
4. MASC owns Keeper scheduling, recurrence judgment, durable inbound delivery,
   async-terminal disposition, product correlation, and dashboard presentation.
5. OAS owns executable identity, provider protocol, Tool invocation, recursive
   execution topology, replay, hook facts, async operation facts, and the
   lossless execution read model.

There is no MASC `Any.t`, no parallel executable registry, no second execution
DAG, no re-declared OAS progress type, and no compatibility dispatcher.

### §0.1 Reconciliation with the current MASC bridge/admission Drafts

MASC main at `d5bd126498` includes two narrower Drafts that were written before
this end-to-end ownership cut:
`RFC-masc-oas-bridge-total-llm-dispatch-boundary` and
`RFC-shared-admission-primitive-knob-binding-policy`. Their useful decisions
remain:

- every MASC-originated LLM request crosses one typed product boundary;
- resource ownership and queue pressure are explicit and observable;
- a declared configuration field is either consumed by its real typed owner
  or rejected;
- slow independent judgment work leaves the initiating Keeper lane free.

The following target clauses do **not** survive this RFC because retaining them
would create a second OAS policy authority or a second live path:

1. MASC does not own provider/model retry, fallback, transport admission,
   provider-call timeout classification, or a parallel provider dispatch
   planner. Those are OAS facts and transitions. A MASC product boundary
   supplies the product caller/lane and one opaque OAS runtime reference.
2. `budget_s`, cost, token count, turn count, elapsed time, and repetition
   metrics are observations only. They cannot reject a call, change recurrence,
   pause a Keeper, cancel a root, or select another provider. An OAS transport
   timeout remains a typed attempt outcome; the originating MASC input remains
   durably pending or explicitly settled.
3. The target does not retain `run_safe` beside `run_bounded`. One hard-cut
   product dispatch surface replaces every direct wrapper call and deletes its
   displaced entry points in the same complete migration slice.
4. `Skip_if_full` cannot dispose of a durable Keeper, Board, Goal, Task, HITL,
   Connector, Fusion, or async-terminal input. Capacity saturation leaves work
   in its owner queue and creates no fleet-global waiter or lease. Best-effort
   telemetry may be sampled or dropped only because it is not product work.
5. A filename/function-name grep allow-list and a substring scan for
   `*_budget`/`*_concurrency` are not dependency or semantic proofs. The target
   checker consumes OCaml compilation-unit dependencies and typed owner
   declarations used by the runtime itself, as specified in §14.
6. No one-release feature flag, compatibility decoder, or advisory-then-required
   dual path keeps the retired authority alive. Rollback is a source revert,
   not a second runtime implementation.

The bridge Draft and admission Draft must be updated to reference these
ownership decisions in the same documentation cut. Until their conflicting
target clauses are removed, none of the three Drafts may claim to be the
implementation SSOT.

## §1 Product result

The finished product must support these compositions without special paths:

- Keeper as Tool and Keeper array as Tool;
- Fusion as Tool and Fusion array as Tool;
- Agent as Tool and Agent array as Tool;
- ordinary Tool array as Tool;
- one heterogeneous array containing Tool, Agent, Keeper, and Fusion members;
- the same heterogeneous array submitted as durable asynchronous work;
- recursive nesting of those compositions, including Fusion judge-of-judges;
- ordered, lossless dashboard inspection of provider reasoning evidence, Tool
  calls/results, child Agents, nested composites, submissions, operations,
  failures, recovery, and gaps.

The current MASC source already establishes three non-negotiable facts that the
integration extends rather than replaces:

- every Keeper owns one durable FIFO lane and one Keeper failure cannot block
  another lane (`docs/spec/04-turn-lifecycle.md:20`);
- the Keeper queue carries a closed typed stimulus set rather than a string
  classifier (`lib/keeper_runtime/keeper_event_queue.mli:65`);
- MASC currently re-exports OAS thinking-control variants
  (`lib/runtime/runtime_schema.mli:63`), while its separate TOML parser
  (`lib/runtime/runtime_toml.ml:388`) and dashboard encoder
  (`lib/server/server_dashboard_http_runtime_info.ml:1434`) demonstrate the
  drift surface that this RFC removes.

Heterogeneous composition therefore uses the OAS catalog itself. The MASC
runtime builder supplies already-adapted Keeper, Fusion, Agent, and ordinary
Tool values incrementally, seals that single catalog, and exposes it through
the OAS adapter:

```ocaml
let heterogeneous_tool =
  let members = Agent_sdk.Tool_member_catalog.begin_ () in
  let ( let* ) = Result.bind in
  let* () = Agent_sdk.Tool_member_catalog.append members keeper_tool in
  let* () = Agent_sdk.Tool_member_catalog.append members fusion_tool in
  let* () = Agent_sdk.Tool_member_catalog.append members agent_tool in
  let* () = Agent_sdk.Tool_member_catalog.append members ordinary_tool in
  let* members = Agent_sdk.Tool_member_catalog.seal members in
  Agent_sdk.Tool_batch.expose
    ~id:heterogeneous_tool_id
    ~revision:heterogeneous_tool_revision
    ~executable_id:heterogeneous_executable_id
    ~executable_revision:heterogeneous_executable_revision
    ~name:heterogeneous_tool_name
    ~description:heterogeneous_tool_description
    ~sibling_schedule
    ~mode
    ~members
```

The four variables demonstrate one heterogeneous vertical slice; production
assembly repeats the same typed append for each configured product definition
instead of hard-coding names or cardinality. The assembly code can only append
`Agent_sdk.Tool.t` values and cannot inspect or dispatch their hidden executable
witnesses. `Async_tool_batch.expose` consumes the same sealed catalog for the
durable asynchronous form.

“Keeper as Tool” never means that OAS owns an immortal Keeper. One executable
invocation represents one finite request submitted to a MASC-owned Keeper lane.
The lane and character may live indefinitely; the OAS invocation has one exact
input and one exact terminal or durable asynchronous receipt.

“Fusion as Tool” likewise exposes one finite Fusion request. Quorum, panel,
judge, judge-of-judges, and domain result semantics remain MASC-owned. OAS sees
only an opaque typed executable and its recursive child execution facts.

## §2 One semantic owner per fact

### 2.1 OAS-owned truth

MASC consumes the following OAS public values without copying their variants or
reconstructing them from JSON:

- `Executable`, `Executable_registry`, and the binding revision;
- `Tool.t`, `Tool_member_catalog`, `Tool_batch`, and `Async_tool_batch`;
- `Agent_tool` and child Agent execution;
- `Agent_progress`, including `Actions_ready`, `Actions_in_progress`,
  `Continuation_ready`, and `Awaiting_external`;
- provider attempts, finalized provider items, replay frontier, reasoning and
  Tool correlation;
- PreTool/PostTool hook decisions and observations;
- submission, operation, cancellation, recovery, and terminal facts;
- `Execution_read_model`, edges, cursors, and typed read gaps.

MASC must not persist a second copy of the OAS transcript, derive a ToolResult
from rendered text, invent child edges from adjacency, or translate an OAS
closed sum into a second MASC closed sum merely to pass it between modules.

### 2.2 MASC-owned truth

MASC remains the sole owner of:

- Keeper identity, persona, world, lifecycle, and one durable lane per Keeper;
- Board, Goal, Task, Connector, Scheduler, HITL, Job, Memory, and Fusion domain
  state;
- whether and when to begin a finite Agent run;
- configured-LLM recurrence decisions at an OAS progress boundary;
- exact source-space and reply-channel correlation;
- durable delivery of inbound events and late asynchronous terminals;
- product access control and the dashboard's local presentation state;
- conversation compaction, memory selection, and reinjection policy.

An OAS receipt is evidence. It does not pause, stop, retry, or wake a Keeper by
itself. A MASC lane event is scheduling input. It does not rewrite OAS execution
history.

### 2.3 Read model, not another authority

The dashboard joins a MASC lane settlement to its referenced OAS fact and then
pages that fact's OAS-owned root stream. Before a fact reference exists, the
lane delivery remains visibly unsettled; MASC does not persist a second
delivery-to-root link in order to make an in-flight row look complete. The
joined tree is a disposable read projection. It cannot authorize a Tool,
advance a Keeper lane, settle a Fusion run, or become provider replay input.

If a product row needs both domain data and execution data, it stores references
to the two owners. It does not copy one owner's mutable state into the other.

## §3 Minimal MASC integration surface

The implementation should be easy to navigate from its public interfaces. It
needs only these new product-facing bridge modules; product execution
persistence may keep its internal wait relation beside its existing
ownership/index code:

- `Keeper_oas_binding`: adapts a typed Keeper lane capability to one
  `Agent_sdk.Tool.t`;
- `Fusion_oas_binding`: adapts a typed Fusion execution capability to one
  `Agent_sdk.Tool.t`;
- `Product_execution_activation`: solely owns the exact, versioned MASC
  Keeper-delivery/Fusion-run activation encodings and their typed resolution;
- `Keeper_oas_recurrence`: asks the configured LLM for the MASC-owned decision
  at an OAS progress boundary and applies the corresponding OAS public action;
- `Oas_async_terminal_inbox`: durably stages OAS operation-event references and
  projects each exact MASC-owned root to its Keeper lane or Fusion-run inbox;
- `Keeper_execution_projection`: joins a MASC lane delivery/settlement with the
  OAS read pages referenced by its exact execution-evidence fact.

There is no MASC wrapper around `Tool_batch.expose`,
`Async_tool_batch.expose`, or `Agent_tool.create`. The application runtime
builder calls those OAS functions directly. A pass-through facade would add a
second place to learn and maintain the same API.

The two domain adapters return the OAS existential package rather than exposing
their runner internals:

```ocaml
module Keeper_oas_binding : sig
  type error

  val create_tool
    :  keeper:Keeper_ref.t
    -> lane:Keeper_lane_submission.t
    -> definition:Keeper_tool_definition.t
    -> (Agent_sdk.Tool.t, error) result
end

module Fusion_oas_binding : sig
  type error

  val create_tool
    :  fusion:Fusion_definition_ref.t
    -> runtime:Fusion_execution_capability.t
    -> definition:Fusion_tool_definition.t
    -> (Agent_sdk.Tool.t, error) result
end

module Product_execution_activation : sig
  type t

  type product_root =
    | Keeper_lane_delivery of Keeper_lane_delivery_ref.t
    | Fusion_run of Fusion_run_ref.t

  type construction_error
  type decode_error

  type resolution =
    | Product_root of product_root
    | No_product_actor
    | Invalid_masc_activation of decode_error

  val create : unit -> (t, construction_error) result

  val encode
    :  t
    -> product_root
    -> Agent_sdk.Execution_root_activation.t

  val resolve
    :  t
    -> Agent_sdk.Execution_root_activation.t option
    -> resolution
end
```

These signatures intentionally show only the product capabilities and the OAS
result. Durable codecs, executable identity/revision, Tool identity/revision,
input schema, and disclosure projection are fields of each immutable MASC
definition. Construction delegates to OAS `Tool.create`; it does not assemble a
public `Executable.binding` record or choose a runner by a product string.

`Product_execution_activation` owns one private
`Execution_event.External_source.t` value per versioned MASC encoding. Its
resolver compares sources only with `Execution_event.External_source.equal`
and decodes the event identity with the corresponding canonical product codec.
An absent or foreign activation is `No_product_actor`; an exact MASC source
whose identity does not decode is `Invalid_masc_activation`. No other module
owns those source values, codecs, or a fallback interpretation. The application
runtime constructs exactly one immutable codec at readiness; failure to create
either typed external source is a typed readiness failure, not a top-level
exception or deferred fallback.

The binding captures a typed lane/runtime capability. A caller cannot choose a
Keeper, Fusion implementation, executable revision, or handler by placing its
name in free-form input.

No GADT is required in these MASC adapters. OAS already owns the existential
heterogeneous boundary in `Tool.t`. Adding another GADT, first-class module,
functor, or phantom state in MASC is rejected unless it makes a concrete illegal
product transition unrepresentable.

## §4 Any and AsyncAny mean OAS Tool composition

`Any[] as a Tool` is product vocabulary, not a new runtime type.

The application runtime incrementally appends already constructed
`Agent_sdk.Tool.t` values to `Agent_sdk.Tool_member_catalog`, seals the catalog,
and passes it to `Agent_sdk.Tool_batch.expose`. Heterogeneity is retained by the
OAS existential package and exact registered executable witness.

The members may have originated from:

- `Agent_sdk.Tool.create` for an ordinary executable;
- `Agent_sdk.Agent_tool.create` for an Agent;
- `Keeper_oas_binding.create_tool` for a Keeper;
- `Fusion_oas_binding.create_tool` for Fusion;
- an already sealed OAS composite Tool.

`AsyncAny[] as a Tool` passes that same sealed catalog to
`Agent_sdk.Async_tool_batch.expose` with an explicitly registered async runtime.
MASC does not serialize a submission array, mint OAS operation identities, or
append a late terminal as a second ToolResult.

`Keeper[]`, `Fusion[]`, `Agent[]`, and `Tool[]` are therefore named catalog
assemblies, not new execution engines. Serial versus concurrent scheduling is
the OAS `Executable_plan.mode` selected in the immutable composite definition.
An empty or single-member collection retains the exact OAS cardinality law; a
MASC convenience function must not normalize one form into another.

Forbidden alternatives include:

- `Obj.magic`, an untyped closure table, or `Yojson.Safe.t` dispatch;
- matching an executable, Tool, Keeper, Fusion, provider, or model by a name
  substring;
- rebuilding a heterogeneous list after OAS has sealed its member catalog;
- a MASC batch executor beside OAS `Tool_batch`;
- a MASC async publication protocol beside OAS `Async_tool_batch`;
- legacy adapters kept active while the new path runs.

## §5 Lane-per-Keeper recurrence

Each Keeper owns one durable FIFO lane and at most one mutation turn on that
timeline. A different Keeper lane remains progress-capable when this Keeper is
busy, waiting for HITL, awaiting an external provider response, running a long
Tool, or recovering a failed OAS request.

Every finite OAS step stops at one durable `Agent_progress` boundary. MASC does
not call an unqualified hidden run loop. The recurrence policy is:

1. `Actions_ready`: the configured LLM examines the exact typed action source
   and chooses Apply, Defer, or Start unrelated work. Apply contains one
   Execute/Decline decision for every client action and MASC seals it with
   `Agent_client_action_decision_source`; missing, duplicate, foreign, or
   conflicting decisions produce a typed failure before any effect.
2. `Actions_in_progress`: the decision was already committed. MASC resumes the
   exact OAS boundary and never asks the LLM to decide it again.
3. `Continuation_ready`: the configured LLM chooses Continue, Defer, or Start a
   new finite run. Continue calls `Agent.resume_continuation`; Defer retains the
   fact reference; a new run consumes separately committed application input.
4. `Awaiting_external`: MASC records Await external or starts unrelated work.
   An exact external response is supplied through
   `Agent.supply_external_stimulus`; it is not rendered as a fake user message.
5. `Completed`: MASC settles the Keeper lane with a reference to the OAS-owned
   run receipt. It neither copies that receipt nor infers another continuation
   from assistant prose.

The MASC-owned scheduling result is split by the boundary that can consume it.
This small amount of type separation prevents Continue from being applied to an
external wait or Await from being applied to an action set:

```ocaml
module Actions : sig
  type decision =
    | Apply of Agent_sdk.Agent_client_action_decision_source.t
    | Defer of Keeper_defer_reason.t
    | Start_unrelated_run of Keeper_committed_input_ref.t
end

module Continuation : sig
  type decision =
    | Continue
    | Defer of Keeper_defer_reason.t
    | Start_unrelated_run of Keeper_committed_input_ref.t
end

module External_wait : sig
  type decision =
    | Await_external
    | Start_unrelated_run of Keeper_committed_input_ref.t
end
```

Execute/Decline remains the OAS decision-source type; MASC does not mirror it.
The two product-only decisions have no Tool/provider fields and none of these
types re-declares an OAS lifecycle constructor, so they are not a second
`Agent_progress` type.

Every `Start_unrelated_run` reference must designate a newly committed,
unsettled lane delivery/application input. The recurrence bridge encodes that
delivery as a fresh root activation and supplies it to the applicable public
`Agent.start`, `Agent.start_with_history`, or `Agent.continue_with_input` call.
It cannot reuse the activation of the progress boundary that led to the
decision.

The decision call is one finite, schema-constrained LLM judgment. A malformed
or unavailable judgment leaves the referenced progress boundary durable and
returns an explicit failure. The current lane attempt settles with that typed
failure and the still-open OAS boundary reference, so later committed stimuli
remain processable without violating FIFO. A later retry is a new explicit lane
stimulus referencing that same boundary identity; it is not an invisible retry
loop or a duplicate provider input.

The judgment runtime is a typed runtime reference in the Keeper's MASC-owned
configuration and resolves through the OAS runtime/model catalog. Any declared
provider fallback remains an OAS-observed attempt sequence; MASC does not branch
on provider/model names or erase the failed attempt. There is no boolean
fallback, default Continue, repeat counter, elapsed-time strike, string
classifier, or hidden loop limit.

Consequently the current MASC `Keeper_turn_runtime_budget` fail-open runtime
selector, direct no-progress retry loop, and `Keeper_error_classify`-driven
provider rotation leave the execution path. OAS owns the declared provider
attempt/fallback plan and its exact facts. After OAS returns a progress or typed
terminal boundary, the MASC recurrence judgment decides product work; it never
reimplements provider retry policy.

Cost, token, turn, throughput, queue depth, and elapsed time are observations
only. They cannot select Continue/Defer, deny a run, pause a Keeper, or close a
lane. Explicit caller/operator cancellation retains its ordinary structured
concurrency meaning; a timeout observation never deletes the input or partial
OAS facts.

A supervisor/watchdog likewise has no Keeper lifecycle authority. It may emit
an observed-stall fact or operator alert containing exact progress references,
but elapsed staleness, consecutive no-op/no-Tool counts, and fleet storm windows
cannot cancel a turn, mark a Keeper stopped, or reject its next lane item. Only
explicit operator cancellation or a typed irrecoverable owner-store/invariant
failure terminates the affected scope, and neither stops another Keeper lane.

This contract prevents framework-created self-repetition in two places:

- only OAS-finalized provider items selected by the exact replay frontier enter
  the next provider request; dashboard strings, provisional deltas, failed
  attempts, and MASC summaries do not;
- every semantic recurrence crosses a durable progress fact and an explicit
  MASC LLM judgment instead of an automatic “feed output back into input” loop.

If a model itself produces repeated finalized content, the repetitions remain
distinct evidence. The configured LLM may defer or choose a new action, but
MASC must not detect semantics with text equality, substrings, counts, or
timing.

The current `Trajectory.detect_entropy` consecutive Tool/name/argument counter
is therefore deleted from execution control rather than tuned. So are
`CostExceeded` as a lifecycle outcome and `tool_cost_estimate` as a decision
input. Exact usage/cost/repetition observations remain queryable from OAS facts
and metrics; only the configured recurrence judgment may assign semantic
meaning to them.

### 5.1 Awaited product actors cannot form a wait cycle

An awaited Keeper or Fusion Tool introduces a real MASC actor dependency: the
caller lane/run cannot finish its current OAS invocation until the target
lane/run settles the request. OAS must not learn this product graph, and Eio
structured concurrency alone cannot detect a distributed actor cycle.

MASC therefore owns one exact durable wait-for relation whose closed vertex
type contains MASC-owned Keeper-lane and Fusion-run references; each edge also
names its owning OAS invocation. The caller actor is not copied into Tool JSON,
looked up by Agent/Tool name, or captured in a differently configured copy of
the Tool. The Tool runner obtains the committed root with
`Execution_context.root`, reads its activation with
`Execution_root_context.activation`, and calls the sole
`Product_execution_activation.resolve` codec. `Product_root` supplies the
exact caller actor, `No_product_actor` creates no MASC wait edge, and
`Invalid_masc_activation` refuses the awaited enqueue with a typed boundary
error. Causes are retained for display but never select the caller. There is no
default Keeper or string fallback.

Before an awaited enqueue, MASC atomically proposes
`caller_actor -> target_actor` against the immutable active graph when a caller
actor exists. A self-edge or any edge that would close a directed cycle returns
a typed `Awaited_actor_cycle` before target enqueue and before waiting. The
model may choose the durable async Tool, which closes the caller ToolUse with a
receipt and introduces no wait edge.

This is exact graph validation, not recursion depth, elapsed time, a model/name
classifier, or a retry cap. The edge is removed only by exact terminal,
cancellation, or reconciled recovery. Restart rebuilds it from durable open
wait records. The short graph update performs no lane I/O while holding its
state lock; an unavailable/corrupt wait index rejects only new awaited actor
dependencies with a typed error. Existing lanes and async submission remain
progress-capable.

## §6 Durable inbound and busy behavior

Connector, Board, Goal, Task, Scheduler, HITL, Job, Fusion, operator, and async
OAS inputs first commit to the target Keeper lane. Only then may the producer
advance its source cursor or report accepted delivery.

A busy Keeper does not consume and lose new input. The event remains pending
or is held by an explicit inflight lease. A connector may send a separate
busy acknowledgement when its protocol supports one, but that acknowledgement
does not settle the original input.

The lane event stores an exact typed source reference. Large Board content,
Fusion results, provider evidence, and async operation output remain in their
owner stores and are paged when the Keeper reads them. Copying their prose into
the queue would create both a second SSOT and an unbounded hot path.

Processing follows one conservation rule: a leased event becomes exactly one
of pending again, durably settled, or explicitly quarantined with a typed
corruption/unroutable cause. Process failure, cancellation, provider timeout,
or a dashboard disconnect cannot make it disappear.

The target lane settlement is deliberately smaller than the current
`Keeper_execution_receipt.t`:

```ocaml
type execution_evidence =
  | No_oas_execution of Keeper_nonexecution_outcome_ref.t
  | Oas_fact of Agent_sdk.Execution_fact_ref.t

type t = private
  { delivery : Keeper_lane_delivery_ref.t
  ; execution_evidence : execution_evidence
  }
```

`Oas_fact` may reference an open progress boundary or terminal fact; MASC loads
and matches the OAS-owned view instead of adding a local status constructor.
It is the result evidence for this lane settlement, not a second root identity,
root status, or delivery-to-root index. Root activation and execution facts
remain OAS-owned; the lane delivery remains MASC-owned. The same delivery may
appear as repeatable causal evidence on later runs, but only the run activated
by that delivery can settle it. A later finite run first commits a new lane
delivery/committed-input reference and therefore receives a different root
activation.

Keeper/Goal/Task/Board effects remain events in their respective owner stores
caused by this delivery, not fields copied into the settlement. Provider/model,
attempt, Tool, reasoning, usage, cost, timing, fallback, stop, and error facts
come from the OAS read model or derived telemetry and never become behavioral
fields in this MASC record.

## §7 Late asynchronous terminal and wake

OAS async submission closes the original ToolUse with one durable receipt. A
later operation terminal is a new typed fact and never mutates that ToolResult
or the closed provider turn.

`Oas_async_terminal_inbox` consumes the OAS operation event stream without
making one unavailable product owner a head-of-line block for every other
owner:

1. read one exact event and its cursor;
2. follow its OAS-owned structural edges to the exact root and resolve that
   root's optional activation only through `Product_execution_activation`;
3. in one MASC inbox commit, store only the OAS event/root references, the typed
   product-owner resolution (`Keeper_lane`, `Fusion_run`, `No_product_actor`, or
   typed invalid-MASC-activation), and the next OAS source cursor;
4. independent per-owner projectors commit an
   `Oas_async_terminal_arrived` reference to the exact Keeper lane or Fusion-run
   inbox and then mark that staged row delivered;
5. signal only the owner whose destination commit succeeded.

The inbox commit, not a target-lane write, is the conservation boundary for the
source cursor. An unavailable Keeper/Fusion store leaves its reference staged
and retryable while other owners continue. The inbox never copies the OAS
terminal payload or status, so this delivery state is not a second execution
store.

Reply loss or process restart repeats the same event identity and resolves to
the already staged or delivered row. It does not create another wake,
ToolResult, or product Job. Cursor advancement without the durable inbox row is
forbidden; delivery marking without the exact destination commit is forbidden.

The lane item contains OAS stream/fact/operation references, not a flattened
result string or another causal envelope. On its turn, the configured LLM
chooses whether to continue related work, defer it, start another finite run,
notify a channel, or do unrelated work.

If the root has no MASC product actor, it is retained as the typed
`No_product_actor` disposition and requires no product wake. If it claims a
MASC activation source but its owner reference is unknown or corrupt, the row
enters an explicit typed unroutable/reconciliation state visible to operators.
Neither case is sent to a default Keeper, broadcast to the fleet, or silently
skipped.

## §8 Exact cross-boundary activation without a second join record

MASC does **not** add a `Keeper_execution_envelope`, `root_link`, root-status
record, or delivery-to-root lookup table. The Keeper lane delivery is the sole
MASC authority for product/source-space identity. The OAS stream is the sole
authority for root identity and execution facts. Goal, Task, Board, Connector,
and Fusion remain weakly coupled because they retain only their existing lane
delivery references.

OAS separates two generic concepts:

- `Execution_root_activation.t` is the optional durable root-activation key.
  Reusing one activation with byte-equal input, selected history, Agent
  definition, causes, and continuation predecessor returns the existing
  root/progress boundary; any mismatch is a typed conflict before another
  provider effect.
- `Execution_event.cause = Internal_event | External_event { source; event_id }`
  is repeatable causal evidence. A cause may legitimately appear on more than
  one finite run, so it is never queried as a one-cause/one-root uniqueness
  index.

For a Keeper-owned root, MASC supplies one exact versioned external activation
whose opaque event identity is the canonical `Keeper_lane_delivery_ref`
encoding. A Fusion-owned root uses its canonical Fusion-run reference instead.
OAS stores and compares those bytes but assigns them no Keeper/Fusion meaning;
MASC alone decodes its own activation sources. The root may also carry the
existing generic external causes needed for causal display, but those causes do
not compete with activation for uniqueness.

The public Agent start/continue surface must accept this generic activation and
cause set. A Tool runner reads them from `Execution_context.root` via
`Execution_root_context.activation` and `Execution_root_context.causes`; the
read model exposes the same committed root facts. MASC commits its lane
delivery before calling OAS. A
crash or reply loss replays the same activation with the same immutable
lane-derived input, history, definition, and cause values through the public
Agent API: a crash before root commit creates the root; a crash after root
commit returns the existing boundary. The eventual lane settlement stores only
the returned OAS fact reference as its result evidence.

Repair never selects a root by external cause alone, internal manifest ID,
message text, timestamp, model output, or first/latest scan. If exact activation
replay cannot prove equality, the lane remains explicitly unsettled with the
typed OAS conflict/uncertainty; MASC does not fabricate a link.

## §9 Lossless hierarchical dashboard projection

The renderer begins only from a lane settlement's `Oas_fact` and pages that
fact's OAS `Execution_read_model` stream. A delivery whose activation replay
has not returned an OAS fact renders as the exact MASC unsettled/reconciliation
state, not an empty execution and not a guessed root. The projection preserves
the OAS-native AgentRun, Turn,
ProviderExchange, ProviderAttempt, ExecutableInvocation/Attempt, child
AgentRun, Submission, and Operation nodes plus their typed structural/causal
edges. This RFC does not carry a hand-maintained copy of that graph. The
human-facing diagram and renderer exhaustiveness fixtures must be generated
from the compiled OAS/MASC interfaces and owner runtime declarations described
in §14.

The normal view follows these laws:

- ordering comes from committed cursors and typed edges, not wall-clock sort;
- provider provisional deltas remain addressable by attempt/item/sequence;
- a finalized provider item supersedes its provisional display fragments in
  the normal view without deleting them from diagnostic inspection;
- reasoning summary, provider-exposed reasoning, semantic assistant content,
  Tool call, Tool result, and metadata-only evidence remain distinct blocks;
- Tool calls and results join by exact OAS correlation, never text or array
  position alone;
- equal text in different finalized item identities is rendered as distinct
  evidence, while one finalized item is never appended several times because
  several deltas carried overlapping text;
- async terminals appear under their Operation and, when scheduled into a new
  Keeper run, through that new lane delivery's separate OAS root activation;
  they are not moved under the old ToolResult;
- missing facts produce the exact typed OAS or MASC gap. The server never
  synthesizes “result missing,” skips to the latest cursor, or fabricates an
  assistant error message.

Collapse/expand is client-local state keyed by the stable node reference. It
does not update OAS facts, MASC receipts, or server snapshots. A collapsed
subtree still reports exact child/fact counts available from the page/index;
opening it continues from its stored cursor.

A cursor gap is a first-class row carrying the affected stream, requested
cursor, retained boundary, and typed recovery availability. The UI may offer a
reload or diagnostic action supplied by the owner, but it cannot pretend the
missing interval was empty.

The current OAS-native `Event_bus` payload projection is not retained as a
dashboard input. A future nonauthoritative change notification, if the OAS read
model exposes one, may only trigger re-reading an already referenced stream;
dropping every such notification must still allow exact catch-up from
`Execution_read_model`.

MASC main at #25084 made a correct partial ownership repair: Keeper hooks now
derive Tool turn, planned index, and opaque provider Tool-use correlation
directly from the current OAS `Tool.Invocation`
(`lib/keeper/keeper_hooks_oas.ml:460`), and the native event bridge projects the
same current OAS invocation fields (`lib/keeper/keeper_event_bridge.ml:170`).
The target preserves OAS ownership of invocation occurrence and provider
correlation, **not** that legacy public constructor or field shape. At the OAS
hard cut MASC consumes the durable target `Invocation.reference` and typed read
facts; every current `Tool.Invocation`-dependent persistence/projection path is
removed in the same slice.

The target also does not preserve the derived execution store:
`keeper_event_bridge.native_event_to_json` plus the `.masc/oas-events/` durable
copy is retired as an OAS execution replay/dashboard source. That bridge still
manually re-encodes OAS variants, can lose bus delivery, and cannot become a
second transcript beside the Journal. The durable Invocation is read from the
OAS Journal/read model. After cutover no OAS-native execution payload is
written to or read from that directory. MASC-owned custom domain events remain
on the MASC-owned
bus/store; they do not masquerade as OAS execution facts.

The same rule retires `Keeper_tool_call_log` as a full Tool input/output store,
the Thinking/Tool execution rows in `Trajectory`,
`Keeper_agent_run_thinking_trajectory`, and the Tool/turn reconstruction
branches of `Tool_agent_timeline`. A product activity timeline may still join
MASC-owned Task, Board, Goal, and delivered chat facts to referenced OAS nodes,
but it reads reasoning, Tool invocation/result, and turn evidence from
`Execution_read_model`. Audit/action-radius facts remain MASC-owned only when
they record a product authorization or side effect, and then store the exact
OAS invocation reference rather than another reasoning/input/output payload.

The server exposes incremental, count-and-byte-bounded pages and indexed edge
reads. It must not rebuild the whole Keeper timeline, decode all Tool payloads,
or hold a fleet-wide lock for each dashboard refresh. Provider-native private
reasoning remains inaccessible unless the OAS disclosure contract explicitly
exposes it; MASC never reconstructs hidden chain of thought.

## §10 Hooks, Gate, and domain policy

OAS PreTool/PostTool hooks run once for each actual OAS invocation and remain
in the OAS Journal/read model. MASC does not maintain a parallel hook timeline.

A MASC Gate or domain invariant may be implemented by a MASC-supplied OAS hook
or by the Keeper lane before submission, depending on the natural authority:

- objective typed input, BasePath containment, sandbox identity, and exact
  authorization are deterministic domain boundaries;
- semantic approval/relevance is a configured-LLM or HITL decision;
- a pending HITL request is durable and nonblocking;
- resolution wakes only the owning Keeper lane and resumes by exact reference.

If a PreTool hook blocks, the dashboard reads the OAS block decision and one
ToolResult from OAS. MASC may join its Gate reference as product metadata, but
must not emit a second Tool terminal.

## §11 Runtime binding/capability SSOT and issue #22654

Issue #22654 correctly identified a local MASC mirror of OAS
`thinking_control_format`. PR #22755 changed the type to an OAS re-export, so a
new OAS constructor now breaks exhaustive MASC pattern matches at compile time.
That fixed the type-identity part of the problem.

The hard cut is not complete. At the inspected MASC baseline:

- OAS already contains `Thinking_object_adaptive` and the canonical label
  `thinking_object_adaptive` in `Llm_provider.Capability_vocab`;
- `Runtime_schema` re-exports that constructor;
- `runtime_adapter` and the dashboard have explicit arms for it;
- `Runtime_toml.parse_thinking_control_format` still has no accepted input for
  it and owns a separate hand-written list of labels and aliases.

The target removes the MASC semantic mirrors for OAS `api_format`, transport,
credential, provider, model, and concrete binding declarations. This includes
`Runtime_schema.thinking_control_format`, the entire local
`Runtime_schema.model_capabilities` record/default,
`Runtime_schema.model_spec` capability/prefix fields, the concrete
provider/model/price/keep-alive/`num_ctx` binding record, and the field-by-field
`Runtime_adapter.model_capabilities_override_of_model_spec` projection. The
identity function `oas_thinking_control_format` is deleted with that mirror.

`runtime.toml` remains MASC-owned for logical runtime IDs, Keeper and subsystem
role assignments, world/persona selection, and the location of operator
declarations. Its provider/binding sections are parsed by the public OAS codec
into OAS-owned immutable declarations; MASC retains opaque binding/runtime
references, not another provider/model record. A named provider/model resolves
to one OAS `Provider_binding_reference.t`; an operator custom deployment goes
through the OAS checked custom-binding constructor and its exact
codec/route/evidence row. Credentials become the OAS secret/declaration type at
this boundary and are never copied into a MASC semantic variant.

An OAS binding/runtime definition owns backend admission and its declared
fallback attempt plan. MASC runtime “lanes” no longer carry ordered provider
candidate lists or pricing/capability data; they map a product logical role to
one OAS runtime reference. MASC does not reconstruct an OAS `Capabilities.t`,
call a provider/model prefix lookup, combine individually valid
provider/model/codec fields into an unchecked cross-product, or choose a first
capable model from declaration order. Request preferences such as streaming or
reasoning control are typed call intent, not claims that a binding supports
them; OAS validates them against that exact row before dispatch.

OAS `Capability_vocab` is the vocabulary SSOT. Its target public hard-cut API is
`decode_thinking_control_format` over the exact `{ label; token }` wire pair and
the exhaustive inverse `encode_thinking_control_format`. Decode compares
canonical labels exactly and returns typed `Unknown_label of string`,
`Token_required`, or `Token_forbidden` errors.

MASC extracts the two TOML fields into OAS
`Capability_vocab.thinking_control_format_fields` and calls
`decode_thinking_control_format` directly. Dashboard output calls
`encode_thinking_control_format` directly.
Canonical OAS labels are the only accepted values; current hyphenated aliases
are migrated in checked-in/deployment configuration and then removed. The
legacy normalizing `thinking_control_format_of_label_and_token` cannot sit on
MASC readiness or request paths; any one-time configuration rewrite is an
offline migration, not a shipped compatibility path. Otherwise an alias table
and lossy normalization remain hidden semantic inputs despite having moved
repositories.

Unknown/noncanonical labels, a missing token for a token-bearing format, and a
token supplied to a tokenless format return the exact typed configuration error
before server readiness. There is no local list to update and no silent
downgrade to `No_thinking_control`.

The same rule applies to future provider capability axes: MASC may own where a
field appears in `runtime.toml`, but not a second semantic vocabulary or
provider/model classifier.

An `OpenAI-compatible` declaration identifies a transport/API family, not
reasoning, Tool, replay, streaming, or multimodal equivalence. MASC passes an
exact OAS binding, wire-contract revision, and catalog evidence. An unknown or
unsupported contract fails readiness or request preparation with zero provider
requests; MASC never probes behavior by catch-and-retry or provider/model name.

The same hard cut applies to error classification. At the inspected OAS main,
the public `Agent_sdk.Error` surface exposes full `to_string` and
`is_retryable`, but no non-identifying typed kind with a canonical printer.
MASC therefore still owns `Oas_compat.error_kind`, a hand-maintained
`sdk_error`-to-string table used at two Keeper logging/manifest call sites. The
target OAS representation-owning unit adds
`Error.category : sdk_error -> category` and `Error.category_label`. MASC
consumes those functions directly and deletes `lib/oas_compat`. MASC must not
add another local category type or expand the compatibility table while that
upstream generic API is pending.

## §12 OCaml 5.x and Eio implementation discipline

The implementation optimizes for product readability, not type-system display.

- Keep definitions, recurrence reduction, activation encoding, and read
  projection pure over immutable values. Mutable queues, cursors, registries,
  and fibers have one explicit owner.
- Use an abstract type only for a real authority or lifecycle boundary. Use a
  closed variant only for a finite product decision. Do not add a functor,
  GADT, first-class module, phantom state, or alias layer when an ordinary
  record/function preserves the same invariant.
- Public `.mli` files show the sole producer and consumer. There is no
  cross-compilation-unit “friend” convention or hidden constructor reached by
  module-name discipline.
- Every finite OAS call and awaited composite is attached to its caller-owned
  Eio structured scope. Work that outlives that scope is a durable async
  Operation, not a detached fiber.
- One blocked Keeper lane, Tool CPU pool, Fusion operation, or dashboard reader
  cannot own another Keeper's progress resources. Pure CPU work uses the OAS
  executor authority appropriate to the binding; blocking/non-cooperative work
  uses a declared process-isolated async backend.
- The process owns one application-lifetime OAS execution runtime. A Keeper,
  Agent, Fusion, or composite definition does not allocate its own executor
  pool, registry, repair supervisor, or dashboard reader. One execution runtime
  is not one model/provider: it may resolve many typed local, hosted,
  OpenAI-compatible, Anthropic-compatible, and fallback bindings from the OAS
  catalog.
- Recoverable failures use typed `result`. Unexpected exceptions retain their
  backtrace and are translated once at the owning infrastructure boundary.
  Cancellation, cleanup failure, and the primary error are never swallowed.
- Resource/page limits are explicit caller inputs needed for bounded reads and
  workers. They are not semantic budget gates and never pause or terminate a
  Keeper.

An LLM reading `Keeper_oas_binding.mli` should be able to find the Keeper lane
capability, immutable definition, OAS Tool result, and typed construction error
without searching provider names or a registry of string handlers. An LLM
reading `Keeper_oas_recurrence.mli` should see exactly where each OAS progress
boundary is judged or resumed.

## §13 Product completion evidence

Completion is proved by real vertical slices, not by keeping old behavior alive
behind flags.

### 13.1 Boundary and SSOT gates

- a dependency test proves OAS has no MASC import or product constructor;
- MASC has no local `Any`, executable registry, OAS progress mirror, reasoning
  dialect mirror, or execution topology writer;
- MASC has no semantic provider/model/binding mirror,
  `Runtime_schema.model_capabilities`, capability default, model prefix matcher,
  ordered provider fallback lane, or field-by-field OAS projection;
- no `Trajectory.detect_entropy`, cost outcome, Tool/Thinking trajectory row,
  or other count/text/time/budget observation can drive Keeper recurrence;
- stale/no-op watchdog observations cannot cancel, pause, or rewrite Keeper
  lifecycle state;
- MASC has no provider-error classifier, fail-open runtime selector, or
  same-turn provider rotation loop; declared fallback attempts are OAS facts;
- there is no checked-in OAS API fingerprint JSON, `oas_compat` classifier, or
  local OAS closed-sum/record mirror; the checker reads the pinned compiled
  interface itself;
- a Keeper lane settlement contains only its delivery and an owner fact
  reference; schema/interface checks reject the retired OAS payload fields and
  compatibility decoder;
- MASC has no execution envelope, root link, delivery-to-root index, or
  cause-to-root selector; root idempotency is the OAS activation index and
  repeatable causes remain causal evidence only;
- an AST/interface gate rejects local OAS closed-sum redeclarations and
  pass-through batch/Agent facades;
- every MASC logical runtime reference resolves exactly once through an OAS
  catalog binding or checked custom-binding codec, or returns a typed
  unsupported result; no OAS binding row, capability codec, or catalog is
  copied or generated into MASC;
- current `runtime.toml` examples, including Ollama/OpenAI-compatible bindings,
  load only through the OAS canonical capability/binding codec;
- local Ollama and Ollama Cloud remain distinct exact binding revisions when
  their verified wire facts differ, while moving an unchanged binding between
  physical endpoints changes no capability; an arbitrary OpenAI-compatible or
  Anthropic-compatible endpoint gains no Tool/reasoning/replay capability from
  its URL, model spelling, or transport family.

### 13.2 Executable product slices

- one Keeper as awaited Tool;
- serial and concurrent Keeper arrays through `Tool_batch`;
- one Fusion and a Fusion judge-of-judges collection;
- one Agent through `Agent_tool`;
- one heterogeneous Tool/Agent/Keeper/Fusion collection;
- the same collection through `Async_tool_batch`, with the caller continuing
  unrelated work before terminals arrive;
- a nested member that invokes another heterogeneous collection, with every
  invocation, hook, result, and child Agent visible under the exact OAS tree.

### 13.3 Recurrence and self-repetition gates

- every `Actions_ready` action is Execute or Decline exactly once before any
  effect;
- `Actions_in_progress` recovery never calls the LLM again;
- Continue consumes one exact `Continuation_ready`; reply loss returns its
  existing successor;
- Defer performs zero provider requests and keeps the fact reloadable;
- Start_new_run commits a new lane delivery/application input, uses that
  delivery's distinct root activation, and never relabels a same-run Tool
  continuation;
- Await_external holds no caller scope and accepts only an exact requested
  response;
- failed attempts, provisional deltas, dashboard strings, and reasoning display
  text are absent from provider replay unless the OAS adapter marks the exact
  finalized artifact replayable;
- repeated finalized model content remains observable but triggers no local
  string/count/time/budget rule.
- awaited Keeper/Fusion self-delegation and `A -> B -> A` reject the exact
  product-actor cycle before the closing enqueue, while an acyclic awaited edge
  and a durable async self-delegation retain their declared behavior;
- terminal, cancellation, and crash recovery remove/rebuild the exact active
  wait edge without a TTL, watchdog, or stale-time guess.

### 13.4 Crash, late-terminal, and loss gates

Deterministic failpoints cover before/after the MASC lane-delivery commit, OAS
activation/root commit, lane lease, lane settlement, async inbox staging/cursor
commit, destination commit, delivery marking, wake signal, and dashboard page
read.

The oracles prove:

- an accepted inbound event is pending, inflight, settled, or explicitly
  quarantined after every restart;
- reply loss after OAS root commit replays the same
  `Execution_root_activation.t` plus byte-equal input, history, definition,
  causes, and continuation predecessor and creates no second run; reusing the
  activation with one changed field produces a typed conflict and zero
  provider requests;
- one repeatable external cause can appear on multiple differently activated
  roots without becoming a first/latest/unique lookup key;
- one async operation terminal creates one lane item and at most one effective
  wake for its owning Keeper;
- an unavailable Keeper/Fusion destination leaves its terminal reference staged
  without preventing another owner's terminal projection;
- a late terminal never mutates the closed ToolUse or old provider turn;
- an unroutable/foreign terminal is retained with a typed cause;
- provider timeout/cancellation preserves input, partial facts, and one visible
  terminal/composite recording error.

### 13.5 Dashboard and performance gates

- one-fact and one-byte paging traverses the same hierarchy without ordinal
  narrowing, duplication, or loss;
- a finalized item displays once while diagnostic mode can still inspect all
  ordered deltas;
- Tool call/result, nested composite, child Agent, submission, operation, hook,
  failure, and recovery edges render from typed references;
- OAS and MASC cursor gaps remain distinct typed gaps;
- collapse/expand changes only client-local state;
- dropping every nonauthoritative refresh notification still catches up
  byte-identically from the OAS read cursor, and no execution route reads
  `.masc/oas-events/`,
  `Keeper_tool_call_log`, Thinking/Tool `Trajectory` rows, the retired execution
  receipt, or a reconstructed `Tool_agent_timeline` Tool/turn row;
- holding Keeper A at an explicit barrier does not prevent Keeper B's durable
  enqueue, OAS step, async terminal import, or page read;
- holding Keeper A beyond every configured observation alert produces visible
  observations but no watchdog cancellation/pause; explicit operator cancel
  remains exact and lane-local;
- holding every Tool CPU worker at an explicit barrier does not prevent OAS
  framework Journal/read work or unrelated Keeper lanes;
- the tests use barriers and committed-event ordering, not sleeps, latency
  thresholds, retry counts, or inferred fleet-size assumptions;
- dashboard refresh work is proportional to requested pages/expanded nodes and
  performs no whole-fleet transcript rebuild or global render lock.

## §14 Generated conformance and no dual documentation source

During design review this RFC is the proposed product contract. Once the first
implementation slice lands, the semantic sources are the compiled OAS public
interfaces/runtime catalogs and the compiled MASC owner interfaces/runtime
declarations. There is no independently edited MASC integration catalog.

A compiler-libs based checker reads those compiled interfaces directly. When a
product relation cannot be derived from module/type dependencies alone, its
owning MASC module exposes one typed declaration that runtime dispatch itself
consumes; documentation and tests do not restate it. The checker rejects
unknown or duplicate owners, reverse OAS-to-MASC dependencies, dependency
cycles, and references to nonexistent OAS constructors. An import/dependency
claim is proved from compilation-unit dependencies and resolved paths, not a
grep of filenames or product vocabulary.

Test evidence is generated from the actual linked test registrations and CI
results, not from a manually maintained claim list. Diagrams, Goal matrices,
flow tables, and renderer exhaustiveness fixtures are generated projections of
the compiled interfaces, owner runtime declarations, and executable evidence.
They are not edited independently in this RFC, dashboard code, or fixtures. A
changed constructor or edge must fail generation until its owner, consumer, and
oracle are updated.

MASC references OAS-qualified symbols and OAS-generated flow identities. It
does not copy the OAS execution matrix, capability vocabulary, or read topology
into the MASC repository.

This hard-cut supersedes the historical `scripts/oas-api-surface.json`
fingerprint and `lib/oas_compat` compatibility-classifier policy described in
`docs/OAS-MASC-BOUNDARY.md`. A committed dump of an OAS interface is still a
second source even if generated. The replacement checker loads the pinned
compiled OAS interface. MASC presentation adapters may exhaustively read an OAS
value, but cannot re-declare its semantic variants, canonical labels, or record
authority.

## §15 Hard-cut migration

1. Pin the released OAS version containing the required recursive execution,
   recurrence, read-model, exact capability codec, checked catalog/custom
   provider-binding declaration codec, `Error.category` /
   `Error.category_label`, durable `Execution_root_activation`, public
   propagation of `Execution_event.External_event` into Agent roots, and root
   activation/cause access from execution context/read facts.
2. Add the two MASC domain bindings and register them through the one OAS
   application runtime.
3. Compose Agent/Keeper/Fusion/Tool arrays only through OAS public catalogs and
   batch adapters.
4. Move Keeper execution to the explicit five-case OAS step surface and add the
   configured-LLM recurrence boundary; delete `Trajectory.detect_entropy`,
   cost-based lifecycle outcomes, and their execution-control callers rather
   than preserving them as fallback guards. Remove stale/no-op watchdog
   stop/pause mutations and MASC-side provider retry/rotation loops; retain only
   typed observations and operator alerts.
5. Activate every finite MASC-owned root with its exact lane-delivery or
   Fusion-run activation, add activation replay/reconciliation, and add the
   staged per-owner durable async-terminal inbox. Do not add a MASC root link or
   cause-to-root index.
6. Replace flat/reconstructed dashboard rows with the joined hierarchical read
   projection and local collapse state; stop the OAS-native serialization and
   persistence in `keeper_event_bridge.native_event_to_json` and remove the
   `.masc/oas-events/` execution source from unified telemetry/dashboard reads.
   Delete `Keeper_tool_call_log` full-I/O persistence,
   `Keeper_agent_run_thinking_trajectory`, and Thinking/Tool execution rows in
   `Trajectory`; make any surviving product activity timeline join OAS
   reasoning/Tool/turn references instead of reconstructing them.
7. Replace the MASC provider/model/concrete-binding schema with logical runtime
   role assignments to opaque OAS runtime/binding references. Remove local
   transport/credential/capability/price/fallback semantic records, model
   prefix matching, identity/field-copy converters, label tables, aliases, and
   dashboard encoders after migrating configuration through the exact OAS
   catalog/custom-binding codec.
8. Delete prior flat Tool pairing, duplicate transcript/event trees, automatic
   feedback loops, and tests for retired compatibility behavior in the same
   cutover series. Replace the current broad `Keeper_execution_receipt` with the
   reference-only lane settlement; there is no runtime compatibility decoder
   for the retired receipt shape.
9. Delete `scripts/oas-api-surface.json`, its snapshot/regeneration path, and
   `lib/oas_compat` after moving its two consumers to `Error.category` /
   `Error.category_label`; then update `docs/OAS-MASC-BOUNDARY.md` so it no
   longer advertises those duplicate authorities.
10. Land generated conformance evidence and every product test in §13.

There is no dual-run period in which old and new execution writers or Tool
dispatchers are both authoritative. If an implementation slice cannot remove
its displaced authority, it is not a complete slice and must not claim the
target behavior.

## §16 Open blockers

At this draft baseline the following are real blockers, not future polish:

1. RFC-OAS-029 and RFC-OAS-037 are not yet released implementations consumed
   by MASC.
2. OAS must release durable generic `Execution_root_activation` CAS on the
   public Agent start/continue API and expose each committed root's activation
   and causes through `Execution_context.root` / `Execution_root_context` and
   read facts. This is required for exact reply-loss/crash replay and
   product-actor resolution without a MASC root link, cause-only lookup,
   internal ID, or scan.
3. OAS must release the exact public `decode_thinking_control_format` /
   `encode_thinking_control_format` pair and the checked catalog/custom-binding
   declaration codec required by `runtime.toml`; current MASC capability and
   provider-binding parsing cannot be deleted before both upstream authorities
   exist, and the thinking parser has already drifted again after #22654.
4. OAS main has not released public `Error.category` /
   `Error.category_label`, so the two MASC `Oas_compat.error_kind` consumers
   cannot yet move to the upstream canonical projection.
5. MASC has not implemented the five-case recurrence bridge, Keeper/Fusion
   bindings, activation replay, staged per-owner async terminal inbox,
   reference-only lane settlement, or
   hierarchical dashboard projection, and the old Event_bus/Trajectory/Tool
   I/O/receipt copies plus provider-rotation and watchdog lifecycle authorities
   remain active.
6. The compiled-interface conformance checker, removal of the historical API
   fingerprint/compatibility classifier, generated projections, and executable
   completion evidence do not exist.

Until all six are closed, “design reviewed” and “runtime feature complete”
must remain separate claims.

## §17 Evidence

- [근거] [OCaml 5.4 manual](https://ocaml.org/manual/5.4/index.html) and
  [compilation units](https://ocaml.org/manual/5.4/compunit.html) — abstract
  interfaces, separate compilation, and module dependency ownership; checked
  2026-07-17; confidence High.
- [근거] [OCaml 5.4 parallel programming](https://ocaml.org/manual/5.4/parallelism.html)
  — immutable cross-domain data and data-race-free synchronization contract;
  checked 2026-07-17; confidence High.
- [근거] [Eio](https://github.com/ocaml-multicore/eio),
  [Eio Switch](https://ocaml-multicore.github.io/eio/eio/Eio/Switch/index.html),
  and [Eio Executor_pool](https://ocaml-multicore.github.io/eio/eio/Eio/Executor_pool/index.html)
  — structured fiber/resource lifetime and explicit CPU executor ownership;
  checked 2026-07-17; confidence High.
- [근거] [Real World OCaml: Functors](https://dev.realworldocaml.org/functors.html)
  — practical module/functor trade-offs; used here to avoid functor ceremony
  where direct capability arguments suffice; checked 2026-07-17; confidence
  Medium-High.
- [근거] `git show 0dc45378d3`, `lib/runtime/runtime_schema.ml`,
  `lib/runtime/runtime_toml.ml`, and
  `Llm_provider.Capability_vocab` at the inspected local baselines — #22654
  type re-export fix and the remaining `Thinking_object_adaptive` parser drift;
  checked 2026-07-17; confidence High.
