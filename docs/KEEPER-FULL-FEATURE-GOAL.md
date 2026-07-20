# Keeper Full-Feature Goal — Unblocked, Durable, Observable

> Status: Proposed implementation contract
> Scope: MASC Keeper execution, Gate, compaction, asynchronous operations, and
> the OAS composition boundary
> Parent design: [`RFC-0000-MASTER-ROADMAP.md`](rfc/RFC-0000-MASTER-ROADMAP.md)

This document states the target behavior and ownership rules. It does not claim
that an open PR, green unit test, or private foundation is already live. Current
commits, PR dependencies, CI, and purge targets belong in companion execution
documents and must be refreshed from their authoritative sources.

Current implementation and PR reachability:
[`KEEPER-FULL-FEATURE-EXECUTION-MAP.md`](KEEPER-FULL-FEATURE-EXECUTION-MAP.md).
Current browser-ready Goal Matrix:
[`2026-07-17-keeper-full-feature-goal-matrix.html`](audit/2026-07-17-keeper-full-feature-goal-matrix.html).

## 1. Copyable Goal

> Rebuild MASC so every Keeper remains an independently progressing durable
> lane; remove generic governance, risk taxonomy, numeric admission, implicit
> execution limits, command/tool/product heuristics, and their derived hard
> prohibitions; retain only objectively provable typed execution invariants;
> route external effects through exact Always Allowed, configured LLM Auto
> Judge, or nonblocking HITL; compose each MASC operation with one or more
> finite OAS Agent runs; make Tool, Model, LLM Agent, Keeper, Fusion, and the
> product shorthand `Any`, `Any[]`, and `AsyncAny[]` compose through typed
> invocation adapters whose asynchronous progress survives restart; preserve
> active identities through MASC-owned LLM compaction and reinjection; and
> prove owner-only wake-up, lane isolation, one-shot grants, Task LLM
> verification, and complete causal observability in CI.

## 2. Success Is Evidence, Not a Percentage

The Goal is complete only when current evidence proves all of these gates:

1. forbidden active-source concepts are absent;
2. OAS owns only generic finite Agent execution and provider/runtime behavior;
3. MASC owns long-lived Keeper product orchestration;
4. Gate modes are exact, non-hierarchical, nonblocking, and observable;
5. each Keeper drains an independent durable queue;
6. waiting operations release runnable capacity and later resume by exact wake;
7. side-effect uncertainty is fenced and never converted into blind retry;
8. MASC-owned LLM compaction preserves active typed anchors;
9. compaction output is reinjected and observable Before/After;
10. Scheduler, Connector, Fusion, and typed Any-as-a-Tool adapters share one
    operation law;
11. Task completion is decided at an LLM boundary;
12. replacement code, focused tests, authoritative CI, and live behavior agree;
13. obsolete implementations, tests, environment knobs, and current docs are
    deleted.

## 3. Two Nested Authorities

```text
MASC durable operation                    OAS finite Agent.run
────────────────────────────────────      ───────────────────────────────
Keeper / Task / Goal / Board owner        Agent turn and provider attempt
Gate / HITL / schedule decision           Tool invocation and tool attempt
Long-lived wait / wake / resume           Structured output and ToolResult
Product checkpoint and Memory             Run-local receipt and crash fence
Compaction and reinjection                Provider-native streaming/capacity
Dashboard product projection              Exact finite-run event projection
```

The dependency remains one-way:

```text
MASC  ──depends on──>  OAS
OAS   ──must not know──> Keeper / Board / Task / Goal / Gate / HITL
                         Fusion / Connector / Scheduler / MASC
```

### 3.1 OAS ownership

OAS owns reusable provider/model catalogs, multimodal protocol values,
streaming, reasoning/tool feedback, finite Agent-run topology, exact ToolUse and
ToolResult structure, invocation-local identity, run-local effect receipts,
provider-native context capacity, typed provider failure, and generic typed
hooks around one finite tool invocation. OAS also owns the generic typed
asynchronous accept/reconcile/cancel/observe protocol and its optional
journal-backed reference runtime. It does not own a MASC long-lived operation
namespace, worker/wake policy, or Keeper lifecycle.

For one finite run, OAS may privately own:

- `Agent_run -> Agent_turn -> Provider_attempt`;
- structured output blocks and tool invocations;
- nested child Agent runs;
- typed `PreTool -> Tool_attempt -> PostTool` lifecycle under each invocation;
- a single-writer run journal and caller-selected durable store;
- persist-before-effect attempt evidence;
- receipt-after-effect evidence;
- typed `Effect_outcome_unknown` and reconciliation fencing.

This is not a Keeper lane. A finite OAS execution scope must close at run
completion and must never become one infinite Keeper-lifetime WAL.

### 3.2 MASC ownership

MASC owns Keeper lifecycle, owner-lane scheduling, durable product operations,
Gate/HITL, Task/Goal/Board/Connector/Fusion state, Scheduler occurrence
semantics, Memory, compaction policy and execution, reinjection, and dashboard
projections. MASC also owns the adapters that expose Keeper, Fusion, Connector,
Scheduler, or another MASC operation through the generic OAS tool boundary.
OAS may provide a generic Agent adapter; it must not gain MASC-specific node
kinds or dispatch rules.

A MASC operation may reference an OAS run and its nodes:

```text
MASC operation_id -> OAS run_ref -> OAS node_id / receipt cursor
```

MASC decides when a Keeper may start, wait, do other work, or wake. OAS reports
the exact finite run outcome; it does not decide product continuation.

“MASC is a read-only OAS execution projection” means only that MASC must not
invent or rewrite OAS run history. It does not make MASC read-only for its own
operation journal, Gate decisions, checkpoints, or Keeper lane.

### 3.3 No duplicate SSOT

The finite OAS run has one simple law:

```text
Execution Journal = sole execution writer and recovery SSOT
Event_bus          = volatile post-commit notification projection
Raw_trace          = read/export diagnostic projection
Durable_event      = deleted
```

The runtime writes each execution fact once to the Journal. Event_bus,
Raw_trace, logs, metrics, and downstream dashboards derive from committed
events and cursors. They cannot append competing execution history or
participate in recovery.

The production cut wires the Journal and deletes the old
`Durable_event.append` and independent `Raw_trace.record_*` execution-write
paths in the same change. There is no dual-write comparison interval and no
compatibility adapter that keeps the old writer alive.

Projection failure cannot relabel, roll back, or hide a Journal commit.

Across the product boundary:

- OAS writes finite Agent-run execution history;
- MASC writes long-lived product operation and Keeper-lane history.

An OAS addition is valid only when a generic OAS consumer can use it without
learning MASC product concepts.

### 3.4 Lossless recursive execution and canonical feedback

The finite-run Journal is a typed recursive tree, not a flat list of display
strings:

```text
Agent_run
└─ Agent_turn
   ├─ Provider_attempt
   │  ├─ reasoning / progress / output blocks
   │  └─ Tool_invocation
   │     ├─ PreTool
   │     ├─ Tool_attempt*
   │     │  └─ child Tool_invocation, Agent_run, or external execution reference
   │     └─ PostTool
   └─ next Agent_turn
```

Every node has an exact typed identity, parent edge, order, lifecycle state, and
canonical payload or payload reference. Recursion may nest Agent and Tool
invocations without flattening. Cross-run shared work is represented by an
exact reference rather than copying history. Cycles are rejected by exact
ancestry identity, not by a guessed depth cap. A child invocation or Agent run
is parented by the exact Tool attempt that created it, never directly by the
logical Tool invocation; otherwise retries would merge distinct child history.

`PreTool` is committed before the handler effect and contains the canonical
input plus the typed OAS hook outcome. A MASC adapter records its product Gate
and admission decision in the referenced MASC operation, not by adding
MASC-specific fields to the OAS node. A rejected invocation has no Tool attempt
and commits a typed rejection. An executed invocation commits its exact
canonical ToolResult or typed failure before any post hook. `PostToolUse` then
observes every committed terminal result; declared failure additionally runs
`PostToolUseFailure`. Observer failure is recorded but cannot rewrite the
ToolResult. The runtime closes the invocation lifecycle after all observers
settle.

For an asynchronous MASC adapter, the ToolResult closes the finite submission
invocation with an acceptance receipt; it does not claim that the long-lived
child operation has completed. Child progress and terminal wake are MASC
operation events and do not fire a second OAS post-hook lifecycle.

The next provider request is constructed only from committed canonical protocol
values:

- each committed assistant output block is admitted once;
- each ToolUse is paired with its exact ToolResult by invocation identity;
- provider reasoning is replayed only through the selected provider's typed
  replay contract;
- stream deltas, progress rows, logs, dashboard text, failed fallback attempts,
  and abandoned retry output are never converted into conversation history;
- a failed attempt remains visible in the Journal without becoming model input.

No substring comparison, repeated-text suppression, prose parsing, or
model-name branch decides what is fed back. If a provider genuinely emits
identical content twice, the two identified nodes remain distinct. If a
projection repeats one node, the projection is wrong; it cannot rewrite the
Journal to conceal the defect.

Cancellation or process interruption cannot delete already committed
reasoning, progress, ToolUse, ToolResult, or output nodes. Recovery closes or
resumes open nodes from their exact persisted state and renders an explicit
cancelled, aborted, unknown, or incomplete outcome. An implicit queue-age,
turn-count, or elapsed-time watchdog cannot erase the run or replace it with a
single synthetic error message.

## 4. Deterministic and LLM Boundaries

Deterministic code may enforce facts that are directly provable:

- typed input and schema validity;
- exact identity, revision, ownership, and one-use consumption;
- path jail and sandbox confinement;
- provider/model capability declared by the selected catalog entry;
- queue claim, append ordering, checksum, cursor, and journal integrity;
- explicit cancellation and hard provider context capacity.

Meaning judgments belong to a configured LLM:

- whether an external effect should proceed;
- whether Task evidence satisfies completion;
- which history is relevant, summarized, remembered, or forgotten;
- whether Board, Connector, Goal, or Task information should wake a Keeper;
- whether a sequence of typed attempts is semantically stalled and should be
  replanned, delegated, switched to another declared runtime, or surfaced for
  human input;
- how Fusion, quorum, or Judge-of-Judges results should be synthesized.

Semantic-stall judgment receives the structured recent invocation tree and
declared outcomes. It is never triggered by repeated substrings, a consecutive
count, elapsed time, cost, tokens, or turn budget. Its result schedules another
explicit activity; it does not silently delete the turn or globally Pause/Stop
the Keeper.

Risk levels, keyword lists, tool names, shell-command inspection, scores,
consecutive counts, fixed ratios, elapsed age, and arbitrary numeric thresholds
do not become objective by being encoded in a type.

Cost, tokens, Keeper turns, exact OAS Invocation schedule coordinates, idle
periods, and elapsed time are observations. They do not authorize Stop, Pause,
failure, or fleet-wide admission.

## 5. Gate Contract

Gate applies to external-effect dispatch, not every internal state transition:

```text
Always_allow | Auto_judge | Manual
```

- Input contains exact Keeper, operation, invocation, normalized typed payload,
  origin, and causal context known by the producer.
- An absent optional fact is persisted as exact absence; it is never
  reconstructed from names, command strings, paths, or later logs.
- Always Allowed matches an exact persisted scope or exact request. It never
  expands by similarity, prefix, tool family, vendor, or inferred risk.
- Auto Judge sends the complete persisted envelope to the explicitly configured
  LLM runtime. Local classification cannot pre-empt or reinterpret the verdict.
- Manual persists pending work and returns control to the owner lane.
- Resolution creates an exact one-shot grant and wakes only the owner Keeper.
- Duplicate exact IDs are a consistency concern. A fleet-wide count cap is not.
- Storage, runtime, persistence, and recovery failures are typed and observable.
- Saving a mode and recovering old work are separate results. A successful save
  remains successful even if recovery reports a typed partial failure.
- “Recovery orchestration completed” must not be presented as “every
  asynchronous Judge finished.” Per-item start and terminal states remain
  explicit.

Always Allowed, Auto Judge, and Manual are alternatives, not a risk hierarchy.
Objective executor invariants remain separate from all three.

## 6. Lane-per-Keeper Contract

Each Keeper owns one ordered event/revision timeline and one durable runnable
queue. Linear means a total order of state transitions, not completion order.

- Any authenticated producer may append exact work for an owner Keeper.
- Only that Keeper's drain may claim and consume it.
- A claim carries owner, operation, revision, and fencing epoch.
- A stale worker cannot commit after a newer owner epoch.
- Checkpoint updates use compare-and-swap or a typed revision conflict.
- A busy Keeper keeps its current runnable work and queues new input.
- A quick connector acknowledgement is itself a durable outbox effect with
  identity and receipt.
- Waiting may retain a suspended fiber as an optimization, but that fiber is
  never recovery truth and retains no global worker, runnable slot, or lane
  claim.
- New runnable work may proceed while another operation waits.
- An exact wake requeues the continuation; duplicate wakes converge on one
  revision.
- Corruption or failure is isolated to the owner lane and never stops unrelated
  Keepers.

Suggested durable operation states include:

```text
Requested -> Claimed -> Running
Requested -> Gate_waiting -> Claimed
Running -> Waiting_child | Waiting_external | Compacting
Running -> Intent_committed -> Side_effect_started
Side_effect_started -> Receipt_committed | Outcome_unknown
* -> Completed | Failed | Cancelled | Recovery_conflict
```

The exact algebra may be refined, but `Outcome_unknown` cannot be collapsed into
success, failure, or automatic retry.

## 7. Side-Effect and Restart Law

General external effects cannot be promised exactly once.

Before dispatch, persist a stable intent containing owner epoch, operation ID,
invocation ID, exact payload digest, and any downstream idempotency key. After
dispatch, persist the exact receipt before projecting success.

- If the provider supports idempotency, replay uses the same stable key.
- If a committed receipt exists, do not execute again.
- If an attempt exists without a provable receipt, record `Outcome_unknown`.
- A non-idempotent unknown enters lane-local reconciliation or HITL.
- Blind resume is forbidden.
- Parent and child operations retain exact join and cancellation edges.

OAS owns the run-local attempt/receipt; MASC owns the product intent,
continuation, and decision about what to do with the reported outcome.

## 8. Asynchronous Any-as-a-Tool

Tool, Model, LLM Agent, Keeper, Fusion, and heterogeneous collections use the
same parent/child operation law.

`Any`, `Any[]`, and `AsyncAny[]` are product shorthand, not untyped JSON types
or public OAS coordinator concepts:

- `Any` is one existentially packed typed invocation with its adapter witness;
- programmatic `Any[]` is an immutable collection with explicit serial or
  concurrent composition; `[]` has the exact empty-result identity;
- `AsyncAny[]` is concurrent submission of that same collection with durable
  handles, not a second payload schema or execution writer.

A provider-visible collection Tool requires at least one call because an empty
wire request has no invocation intent. That schema fact does not become a
programmatic collection-size gate.

The implementation may name these concepts `Invocable`, `Invocation`, or
`Many`. Correctness comes from the typed request/result witness, not the word
“Any”. A wire discriminator is resolved exactly once at the decode boundary;
runtime dispatch cannot use substring matching or free-form type names.

One invocation or one serial/concurrent collection may itself be exposed as a
Tool. Recursive composition uses the same tree: the composite has one outer
`PreTool`/`PostTool` boundary and every child retains its own nested boundary.
Neither the execution writer nor the dashboard duplicates the child events as
flat outer events.

- OAS owns generic Tool, Model-call, finite-Agent adapter mechanics, and the
  typed asynchronous acceptance/reconciliation/cancellation/observation
  façade.
- MASC owns Keeper, Fusion, and other product adapters, the injected
  long-lived operation backend namespace, worker and wake policy, continuation,
  authorization, and application switch.
- An adapter cannot make OAS import or encode Keeper, Fusion, Board, Goal,
  Scheduler, Connector, or MASC variants.
- A parent submits immutable child requests and stores exact child references.
- Children may run concurrently or on their own Keeper lanes.
- Parent waiting releases its claim and later joins by exact continuation.
- Results use a versioned typed envelope with value, error, artifact, runtime
  attempts, provenance, and terminal state.
- Collection results preserve declared input order and an all-settled domain
  outcome for every child. A declared child failure does not cancel siblings.
  Infrastructure failure cancels unfinished structural siblings, preserves
  every committed partial outcome, and never affects unrelated lanes.
- Asynchronous submission atomically commits the submission and every child
  intent, or commits none. It returns one ordered receipt of exact operation
  handles. Acceptance is not completion; ambiguous publication reconciles by
  the same submission identity and request digest.
- A terminal child commit appends one exact continuation event for the owner
  lane. Wake notification may coalesce by the persisted cursor/revision, but no
  terminal event is dropped. Both declared success and declared failure make
  the owner runnable.
- One declared child failure does not stop siblings, quorum, parent, or
  unrelated lanes. Infrastructure failure remains an explicit outer result.
- Cancellation, orphan detection, cycles, partial failure, and quorum are
  explicit graph semantics.
- Scale changes queue depth and observed latency, not correctness rules.

There is no semantic branch or hidden admission cap based on collection
cardinality. Typed backpressure may report unavailable capacity; it cannot
silently drop children, convert ambiguous admission into success, or become a
budget-derived Stop/Pause gate.

## 9. MASC-Owned LLM Compaction

OAS has no reducer, automatic truncation, compaction policy, or overflow retry.
OAS returns typed capacity/overflow facts. MASC queues compaction in the owner
lane and invokes a configured model.

- Compaction is a durable operation and releases the owner claim while waiting.
- A plan binds source checkpoint generation, transcript digest, unit span
  digest, and protected anchors.
- Apply uses compare-and-swap; a stale plan is rejected without changing source.
- The LLM receives canonical message/unit values, not flattened display prose.
- Open ToolUse cycles, active ToolProgress, unresolved effects, artifacts, and
  continuations remain exact.
- Closed terminal history may be reduced only after exact durable joins.
- Output is reinjected as model context, not written as Task/Goal/Board truth.
- Before/After evidence stores source, plan, output, runtime attempts,
  checkpoint, anchors, and reinjection receipt.

Capacity is computed from the complete provider request: system prompt, tools,
memory, multimodal blocks, provider framing, and reserved output. Use
provider-native token counting when available; otherwise preserve typed
`Unknown` rather than guessing from characters.

A fit claim is bound to one exact pending source and the same immutable request
artifact that OAS later dispatches after applying its hooks and model-input
projection. MASC must not reconstruct that provider request. A manual
compaction with no pending source may record semantic reduction, but it cannot
claim that an unknown future turn fits. Source-bound manual and overflow work
must remeasure after compaction because the request artifact changed.

If one compaction request is itself too large:

1. try the next declared compaction runtime candidate;
2. create capacity-safe contiguous waves from typed structural units;
3. preserve immutable anchors and exact source-span provenance between waves;
4. externalize one indivisible payload as a content-addressed Artifact;
5. keep the original source and record typed rejection if all candidates fail.

No fixed importance score, arbitrary ratio, marker string, pair repair, or
silent drop is permitted.

## 10. Memory and Artifact Boundary

Raw large ToolResult and multimodal payloads are content-addressed Artifacts
with digest, length, media type, provenance, and access status.

Memory is deliberate LLM-authored durable knowledge that may reference
Artifacts. Relevance, consolidation, and forgetting are LLM decisions. A
deterministic fallback summary cannot become semantic Memory.

Reinjection records exact Keeper, source trace/turn, block digest, fact IDs, and
checkpoint generation. Volatile echo suppression and “latest N” selection are
not correctness contracts.

## 11. Scheduler, Connector, and Fusion

All producers append the same durable owner-lane operation.

- Connector identity includes connector, space/server, channel, participant,
  inbound event, provenance, and authentication context.
- Inbound dedupe, cursor, and ordering are explicit; spaces remain isolated.
- Outbound work uses a durable outbox, idempotency where supported, and receipt.
- Scheduler occurrences record due, claimed, started, skipped, completed,
  cancelled, and rescheduled transitions.
- iCalendar compatibility preserves UID, RECURRENCE-ID, RRULE, RDATE, EXDATE,
  timezone/DST, update/cancel, catch-up, and misfire semantics.
- Every occurrence passes its configured Gate; a recurring schedule is not an
  infinite grant.
- Fusion and Judge-of-Judges submit typed children and join asynchronously.

## 12. Runtime and Dashboard

Runtime selects Text, Voice, Image, Audio, Judge, and compaction models from
typed provider/model catalogs. Fallback follows explicit candidate order and
declared capability, never names, URLs, or vendor strings.

MASC owns the application-lifetime switch and the single host CPU-allocation
policy. It creates and shares one opaque OAS execution runtime with an explicit
allocation; OAS encapsulates its internal pool and exposes no raw pool or
allocation heuristic. Journal codec, recovery scan, and projection work cannot
create a pool per lane/event or silently fall back onto the Keeper or server
scheduling domain. Resource exhaustion is a typed lane-local result, not a
fleet stop or a reason to discard committed progress.

Dashboard chat preserves causal interleaving of thinking, output, ToolUse,
progress, ToolResult, multimodal blocks, child operations, compaction, and
reinjection. It shows product operation identity and referenced OAS run/node
identity without merging their writers.

The dashboard recursively projects the committed tree. It may fold nodes for
navigation, but it cannot flatten parent/child boundaries, merge identical
content, reorder by arrival time, synthesize a missing ToolResult, or replace
the canonical payload with a summary. A gap is rendered as an explicit gap with
the last durable cursor and recovered through the SSOT reader.

Observability failure never changes durable truth. Journal and receipt commits
precede EventBus, SSE, log, metric, and dashboard projections.

## 13. Required Behavioral Proofs

| Proof | Required behavior |
|---|---|
| lane isolation | Keeper A waits while Keeper B and later A work continue |
| owner fencing | a stale drain cannot mutate a newer checkpoint revision |
| HITL one-shot | pending is nonblocking; exact grant wakes one lane once |
| Auto Judge context | restart delivers the exact persisted request to the LLM |
| side-effect uncertainty | attempt without receipt becomes `Outcome_unknown` |
| canonical feedback | failed attempts and projection text never re-enter model history |
| recursive Journal | nested Agent/Tool/PreTool/PostTool nodes round-trip without flattening |
| async collection | atomic admission returns ordered handles; every terminal child event reaches its owner |
| interrupted run | cancellation preserves committed partial nodes and explicit terminal state |
| server isolation | journal work cannot stall the Keeper or server scheduling domain |
| restart recovery | durable operation and finite OAS run references reconcile |
| active compaction | ToolUse/progress/unresolved effect anchors remain exact |
| oversized compaction | fallback/waves avoid arbitrary truncation |
| reinjection | exact receipt proves which compacted block entered which turn |
| producer convergence | Scheduler/Connector/Fusion converge on owner revisions |
| Task verification | schema-valid LLM evidence decides completion |
| dashboard causality | UI joins operation, run, progress, compact, and finish |
| legacy absence | forbidden source, tests, env knobs, and current docs are gone |

Small immutable fakes are sufficient for semantic tests. Large-cardinality
benchmarks are useful for capacity observation but are not correctness gates.

## 14. Hard-Cut Rule

Legacy behavior is not a compatibility target. Once its replacement is proved,
delete the parser, adapter, fallback, environment variable, fixture,
implementation-shape test, and contradictory current documentation.

Do not create a compatibility shim merely to keep a stack green. Historical
audits may remain only when clearly marked as history.

## 15. Dependency Order

Keep each PR single-contract and independently reviewable:

1. finish the OAS finite-run single-writer hard cut without public complexity;
2. release OAS and pin MASC exactly;
3. compose MASC operation identity with OAS run/node/receipt identity;
4. make per-owner progress and continuation durable;
5. implement owner-only wake, fencing, and restart reconciliation;
6. make compaction a durable lane operation with source CAS;
7. hard-cut Artifact/Memory and exact reinjection receipts;
8. adapt Scheduler, Connector, Fusion, and typed Any-as-a-Tool composition;
9. expose lossless dashboard projections;
10. prove mixed Lane/Gate/compaction/restart behavior;
11. perform the final implementation, test, environment, and documentation
    purge.

## 16. Definition of Done

The Goal is done only when every evidence gate in §2 and every behavioral proof
in §13 passes on current source, authoritative CI, and applicable live runtime,
with the §14 hard cut complete. A private foundation or Draft PR is progress,
not completion.
