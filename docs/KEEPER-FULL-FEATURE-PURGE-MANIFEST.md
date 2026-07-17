# Keeper Full-Feature Purge Manifest

> Status: implementation deletion and replacement contract
> Normative goal: [`KEEPER-FULL-FEATURE-GOAL.md`](KEEPER-FULL-FEATURE-GOAL.md)
> Live map: [`KEEPER-FULL-FEATURE-EXECUTION-MAP.md`](KEEPER-FULL-FEATURE-EXECUTION-MAP.md)
> Source checkpoint: MASC `fd70c8fc7f`, OAS `b2a9478ff3`, pinned OAS `v0.215.0` at `a7ea83fbbf`
> Checked: 2026-07-17 13:23 KST

This manifest names what must die, what must be rewritten, and what is an
objective boundary worth keeping. It is deliberately narrower than a migration
plan: retired execution authorities are not compatibility targets.

[근거] `rg` over both source trees, exact production call-site inspection,
`git merge-base --is-ancestor`, and current PR ancestry; checked 2026-07-17;
confidence High.

## 1. The Entire Journal Law

There are exactly two kinds of authoritative lifecycle history, at different
scopes:

```text
OAS Execution Journal       = one exclusive writer per finite Agent.run scope
MASC Operation Journal      = one independent writer per Keeper-owned partition

Event_bus                   = volatile post-commit notification projection
Raw_trace                   = read/export diagnostic projection
logs / metrics / dashboard  = cursor-backed read models
Durable_event               = deleted
```

OAS writes run, turn, provider, output-block, Tool invocation, attempt, receipt,
and typed unknown-outcome facts. MASC writes Keeper ownership, queue claim,
Gate, Task, Board, Connector, Scheduler, Fusion, wait, wake, compaction, and
checkpoint facts.

Each finite OAS execution scope has one exclusive writer. Each Keeper-owned
MASC partition has its own independent writer and drain. There is no
fleet-global writer, lock, recovery dependency, or failure domain.

MASC stores typed OAS scope, node, receipt, and cursor references. It does not
copy OAS execution facts into a second recovery history. OAS never learns MASC
product types.

### 1.1 One fact, one append

An execution fact is appended once to its owning Journal. Only after commit may
a projector publish it to Event_bus, render Raw_trace, update metrics, write an
export file, or notify the dashboard.

- A projection cannot create lifecycle truth.
- A projection failure cannot roll back or relabel a commit.
- A dropped volatile notification cannot lose durable observation.
- Replay begins at a committed cursor, not at an in-memory subscriber queue.
- Hooks may control their documented synchronous boundary, but are not history.
- A typed Hook outcome that changes execution is committed to the owning
  Journal before the affected transition or effect.
- No read model participates in retry, reconciliation, or Keeper continuation.

### 1.2 One production hard cut

There is no dual-write comparison interval. Inert, unwired foundations may land
independently. The activation change exposes the new writer while removing every
old live call path and publicly selectable writer. Unreachable source, tests,
and docs are deleted as explicit cleanup work. Change size and line count are
review observations only; they do not decide admission, sequencing, release, or
completion.

Temporary adapters may decode a committed event into a projection. They may not
append the same fact to an old store.

## 2. OAS Hard Cut

### 2.1 Delete completely

- `lib/durable_event.ml` and `lib/durable_event.mli`;
- `lib/journal_bridge.ml` and `lib/journal_bridge.mli`;
- `test/test_durable_event.ml`;
- `test/test_journal_bridge.ml`;
- `test/test_agent_auto_dump.ml`;
- their Dune module and test stanzas;
- the `durable.*` duplicate catalog in `docs/EVENT-CATALOG.md`.

`Durable_event` is not a crash-safe execution journal. It accumulates an
in-memory atomic list and later rewrites a file, flattens ToolResult content,
treats a missing file as an empty history, and uses an idempotency key whose
collision cannot prove effect identity.

### 2.2 Delete the public legacy surface

- `Agent_sdk.Durable_event` and `Agent_sdk.Journal_bridge`;
- `Agent_types.journal`;
- Builder's journal field;
- `Builder.with_journal`;
- `Builder.with_auto_dump_journal`;
- `Agent.save_journal`;
- `Agent_tools`' optional `Durable_event.journal`.

The normal OAS caller selects an optional durable execution store through the
finite-run API. It does not assemble journals, bridges, dump callbacks, or
recovery machinery.

OAS nevertheless exposes the minimum read-only composition contract: an opaque
execution reference returned by the finite run, an opaque cursor, and an
immutable cursor-backed projection reader or caller-owned projection sink.
Journal reducer, WAL bytes, writer actor, and reconciliation internals remain
private. MASC never imports a private `Execution_*` module.

MASC selects the OAS scope store under its BasePath and owns its retention
lease. A scope referenced by a durable operation or checkpoint cannot be
garbage-collected. Projection caches are disposable read models, never recovery
history.

### 2.3 Delete independent legacy writes

- `agent_tools.ml`: `append_journal`, FNV idempotency construction, and
  `Tool_called` / `Tool_completed` appends;
- `pipeline_stage_prepare.ml`: the separate `Turn_started` append;
- `pipeline.ml`: separate LLM request, response, and error appends;
- `agent_trace.ml`: independent Raw_trace run, hook, block, and Tool writes.

Raw_trace may remain as a pure projection format and query surface. Its
`record_*`, `start_run`, and `finish_run` functions must not remain live
execution writers.

### 2.4 Required replacement before wiring

The new event algebra must express:

```text
effect attempt durably committed
  -> external effect invoked
  -> exact success or failure receipt durably committed
  -> otherwise Effect_outcome_unknown
```

It must also parent each nested Tool invocation or child Agent run to the exact
Tool attempt that created it, with typed pre/post closure. A retry cannot merge
children into the invocation as a whole. These remain generic OAS nodes; Keeper,
Fusion, Connector, and Scheduler node kinds do not enter OAS.

Unknown outcome forbids blind replay. Idempotent replay is allowed only when
the executor supplies an exact capability or receipt contract. OAS must not
claim universal “Tool effect exactly once.”

### 2.5 Replace, do not preserve, old tests

- Tool execution tests assert one `Tool_attempt -> receipt | unknown` history.
- Telemetry tests assert Event_bus projection order from committed cursors.
- Raw_trace tests cover projection/read/query round trips, not writer APIs.
- Crash tests prove attempt-without-receipt becomes typed unknown.
- Restart tests prove unknown causes zero blind re-executions.
- Projection tests prove Event_bus and Raw_trace share the Journal event ID and
  cursor.

Keep execution store, Journal reducer, lane writer, codec executor, Event_bus
subscriber, and Hook boundary tests when they test their new single roles.

## 3. MASC Writer and Projection Cut

MASC keeps its own product Journal. The following components must stop acting
as alternate lifecycle writers or control authorities.

### 3.1 Rewrite execution joins and current work

- `keeper_execution_join`: replace the process-local
  `tool_use_id -> execution_id` Hashtbl with a durable typed link carried by
  the MASC operation and OAS invocation reference;
- `keeper_current_operations`: project one MASC Operation Journal instead of
  joining two independently authored stores;
- `keeper_execution_receipt`, runtime manifests, Turn records, and Trajectory:
  retain distinct product facts, but derive subordinate OAS execution facts
  from OAS cursors;
- `keeper_agent_run`: remove per-turn `Raw_trace.create` and the untraced
  execution fallback when that writer cannot start;
- `keeper_event_bridge`: become a replayable projection, never another history.

Missing durable joins are typed consistency failures, not an empty successful
lookup.

### 3.2 Remove Event_bus control authority

`keeper_unified_turn_event_bus` currently derives pending Tool counts and
Streaming/Awaiting state from a bounded `Drop_oldest` subscription. That is
lossy control authority.

Nested-run state must come from the committed OAS Journal cursor or an exact
synchronous invocation boundary during the hard cut. Event_bus may notify the
UI, but it cannot decide whether a Keeper is waiting or runnable.

`keeper_event_bridge` and `keeper_telemetry_consumer` must replay from their
typed source authority after restart: OAS finite-run facts use an OAS execution
cursor; MASC-originated product telemetry uses a MASC Operation cursor. Never
merge the cursor families. Remove finite retry-drop queues, synthetic
`relay_dropped` history, and kind-only fallback payloads. Preserve an unknown
event losslessly as typed data or reject it explicitly.

### 3.3 Rewrite volatile audit writers

- `keeper_transition_audit`: remove the authoritative in-memory ring and
  drop-on-overflow queue;
- `keeper_decision_audit`: remove the overwriting process-local ring;
- `keeper_crash_persistence`: do not dequeue a crash record before a successful
  durable append;
- `progress.ml`: remove process-global Tracker authority, derived percentages,
  and inferred ETA.

Each becomes a projection of exact operation events. Percentage or ETA exists
only when the producer or configured model supplied it explicitly.

## 4. Compaction Hard Cut

Compaction is a durable MASC operation:

```text
Compaction_requested
  -> source checkpoint digest and generation
  -> claimed by owner work
  -> configured LLM structured plan
  -> deterministic structural validation
  -> checkpoint compare-and-swap
  -> Before/After projection
  -> owner-only Keeper wake
```

The Keeper lane is released while the LLM runs. Synchronous compaction inside
`keeper_heartbeat_loop_cycle`, `keeper_manual_compaction`, or provider-overflow
recovery must not retain turn admission or block unrelated work.

The #24840 test restored on current `main` proves the As-Is serialization. It
is regression evidence for the old behavior, not the desired contract.

The LLM owns semantic keep, summarize, and drop decisions for ordinary
conversation. Deterministic code owns only typed units, source binding,
coverage, ordering, protected active anchors, typed continuation stage, and
checkpoint CAS.

Completed ToolResult or ToolProgress prose cannot be reduced until the durable
operation Journal, exact receipt, canonical payload digest, and cursor span
provide an exact join. Canonical bytes may be inline or addressed by an
Artifact reference. Open ToolUse, active progress, unresolved suffixes, and
currently unjoined closed Tool cycles remain exact.

Current-main defects that must be removed in the replacement slice:

- `keeper_run_prompt` applies `repair_broken_tool_call_pairs` immediately before
  provider dispatch and can delete a checkpointed open ToolUse;
- deleting that repair alone exposes a second defect: an unresolved ToolUse
  cannot be sent with a new user goal, and the checkpoint does not durably say
  which exact Tool occurrence is awaiting its ToolResult;
- the current LLM plan receives no selected-runtime fit target;
- acceptance checks only that serialized bytes decreased, not that the complete
  next request fits the provider-native context window;
- a transcript larger than the compaction model's own window has no durable
  LLM wave protocol;
- `primary_model_max_tokens` configures the working context but is not a
  provider-native full-request count or an acceptance proof.

The replacement uses closed structural units and persists the open suffix with
a typed exact Tool continuation. While that continuation is unresolved it
performs zero provider dispatches and defers only that activity. A matching
typed ToolResult closes the cycle and wakes the exact owner; only then may the
closed checkpoint prefix reach provider dispatch. The complete next request is
counted through a provider-native contract, and `Insufficient_reduction` is
durable work rather than an inline retry cap. Transcript or string inference,
synthetic ToolResult insertion, and fleet-wide blocking are forbidden.

The OAS dependency is ordered: exact invocation propagation, production
Execution Journal single-writer settlement authority, and only then a public
pending-tool resume operation. `Agent.resume` in OAS 0.215 reconstructs state
but does not settle pending Tool effects. MASC must not call internal
`Agent_tools`, accept a caller-synthesized settlement, or replay an effect whose
commit outcome is unknown.

Delete the `Deterministic` / `extractive` compaction mode and
`MASC_KEEPER_COMPACTION_MODE`.

Delete the ratio, message, token, and cooldown fields across config, runtime
parameters, API/schema, dashboard, tests, and current docs. On current `main`
they are producer/display-only dead configuration, not real compaction
triggers, so preserving or “rewiring” them would invent a false contract.

Compaction enters through an explicit Manual request, typed provider overflow,
or a future explicitly configured Scheduler occurrence. No silent clamp,
estimated token boundary, or projection field may trigger semantic mutation.

## 5. Tool Output and Artifact Hard Cut

Delete policy embedded in:

- `tool_bridge.default_externalize_threshold_bytes`;
- `MASC_TOOL_EXTERNALIZE_THRESHOLD_BYTES`;
- `MASC_TOOL_EXTERNALIZE`;
- string-parsed boolean switches;
- best-effort externalization with inline fallback;
- `keeper_artifact_hydrator.default_keep_recent`;
- `MASC_TOOL_HYDRATE_RECENT`;
- newest-N mutable hydration;
- `keeper_run_tools_hooks` hydration wiring;
- fixed Tool output character caps and washing tests.

The replacement is exact:

- every canonical result carries a payload digest, byte length, media type, and
  provenance;
- bytes remain typed inline or are stored as a content-addressed Artifact
  according to a provider-independent producer/content contract;
- provider capability decides only the model-visible projection; unknown
  capacity uses an explicit Artifact reference and fetch operation;
- the compaction LLM decides semantic presentation, not storage identity;
- no threshold or latest-N rule decides semantic importance;
- store failure is typed and visible, never silent inline substitution.

Keep exact Artifact integrity and fetch tests. Rewrite HTTP Artifact routes as
authenticated exact retrieval, not implicit public ToolResult policy.

## 6. Memory Hard Cut

### 6.1 Replace the volatile Memory lane

Delete the process-global closure queue, maximum-pending default, saturation
drop, inline fallback, and `MASC_KEEPER_MEMORY_LANE_MAX_PENDING` from
`keeper_memory_lane`.

Use durable typed work per Keeper. Backpressure may delay that Keeper's Memory
work, but cannot drop it, execute it under another owner, or stop other lanes.

Also delete Memory OS cadence-turn gates, recent-N message windows,
fleet-global admission slot `1`, and their environment knobs/tests. Replace the
global slot with independent durable owner work. Delete the synthesized
`max_tokens=4096` default; keep only an explicit provider request bounded by the
selected model's declared capability.

### 6.2 Delete the legacy Memory Bank semantics

Delete active Memory Bank and recall behavior that uses:

- Tool payload preview caps and deterministic Long_term promotion;
- tuned priority, recency, kind caps, recurrence promotion, or recent floors;
- lexical/Jaccard/regex/keyword similarity and topic bonuses;
- deterministic fallback summaries or compaction;
- fixed “three recent” long-term injection in `keeper_turn`;
- silent `Error -> []` semantic loss.

Delete the related environment surface:

- `MASC_KEEPER_MEMORY_MAX_NOTES`;
- `MASC_KEEPER_MEMORY_COMPACT_TRIGGER_BYTES`;
- `MASC_KEEPER_MEMORY_MAX_LENGTH`;
- `MASC_KEEPER_MEMORY_PLACEHOLDERS`;
- `MASC_KEEPER_MEMORY_CONSENSUS_PATTERN`;
- `MASC_KEEPER_MEMORY_LLM_SUMMARY`;
- `MASC_KEEPER_BANK_LONGTERM_INJECT`.

Delete subsystem tests whose purpose is to preserve those heuristics, including
the long-term injection flag and deterministic consolidation provenance.

Keep Memory OS typed facts, provenance, explicit expiry, supersession, codecs,
and application of a configured LLM plan. The model owns semantic existence,
relevance, consolidation, remembrance, and forgetting.

## 7. Other Active Purges

- Delete dead `exec_budget` and its tests; it has no production caller.
- Rewrite eager vision caps and text placeholders into typed Artifact plus
  provider-capability/failover operations.
- Remove retired meta-key scrub-on-boot migration after the new schema cut;
  reject unknown persisted state explicitly instead of silently rewriting it.
- Rewrite Auto Judge drain reporting so every item has typed start and terminal
  status; concurrency scheduling may remain when it never drops work.
- Rewrite current docs that still assign Context_reducer, default turn limits,
  or automatic compaction authority to OAS.
- Delete or supersede active tests whose only purpose is proving retired
  reducers, sentinels, caps, drop queues, or compatibility migration.

Historical withdrawn/rejected RFCs may remain when clearly non-normative.

## 8. Objective Boundaries to Keep

Do not confuse every number or bounded resource with Keeper governance. Keep:

- typed schema and identity validation;
- path jail, sandbox confinement, and declared provider capability;
- exact Journal checksum, ordering, revision, cursor, and fencing;
- explicit caller-selected request deadlines;
- provider transport/connect/body limits that fail one operation explicitly;
- bounded shutdown cleanup;
- isolated evaluation-harness turn/cost limits;
- Event_bus subscriber bounds when loss is measured and replay is from Journal;
- exact Always Allowed, one-shot grants, Auto Judge, and nonblocking HITL.

Current MASC source has zero active `keeper_effect_request`, risk-class ladder,
R0-R3, `hard_forbidden`, operator-only floor, or automatic-eligibility
authority. Do not recreate them under new names.

## 9. Landing Order

1. Re-slice the OAS execution stack and separate unrelated provider changes.
2. Finish typed attempt, receipt, and unknown-outcome semantics.
3. Build cursor-based Event_bus, Raw_trace, and checkpoint projections.
4. Wire the OAS Journal and delete all legacy OAS writers in the same cut.
5. Release OAS and pin the exact release in MASC.
6. Wire the MASC Operation Journal and one durable owner queue per Keeper.
7. Move compaction to a durable operation that releases and wakes its lane.
8. Cut Tool output/hydration heuristics and preserve exact Artifact identity.
9. Replace the volatile Memory lane and delete legacy Memory Bank semantics.
10. Wire Scheduler, Connector, Fusion, Model, Agent, Keeper, and Tool
    collections through the same operation law.
11. Purge stale tests, environment knobs, active docs, and migration residues.
12. Prove mixed-Keeper restart, projection replay, Gate, compaction,
    reinjection, and dashboard causality in CI.

Each implementation PR follows one explicit contract. A replacement consumer
and deletion of its old authority land together; no fake green, Stub, silent
fallback, or compatibility writer is accepted.
