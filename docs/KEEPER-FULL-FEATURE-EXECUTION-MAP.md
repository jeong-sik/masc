# Keeper Full-Feature Execution Map — OAS and MASC

> Status: live implementation checkpoint, not normative architecture
> Normative contract: [`KEEPER-FULL-FEATURE-GOAL.md`](KEEPER-FULL-FEATURE-GOAL.md)
> Checked: 2026-07-17 13:23 KST
> MASC `origin/main`: `fd70c8fc7f`
> OAS `origin/main`: `b2a9478ff3`
> Latest published OAS and MASC pin: `v0.215.0` at `a7ea83fbbf`
> Browser matrix: [`2026-07-17-keeper-full-feature-goal-matrix.html`](audit/2026-07-17-keeper-full-feature-goal-matrix.html)

This document explains why both repositories are changing, what is already on
`main`, what exists only inside a stacked branch, and where the remaining work
belongs. Refresh every live fact before acting.

[근거] `git fetch origin --prune`, `git rev-parse origin/main`,
`gh pr view/list/checks`, and commit ancestry checks with
`git merge-base --is-ancestor`, and exact source call-path inspection; checked
2026-07-17 13:23 KST; confidence High.

## 1. Read “Merged” Correctly

GitHub marks a PR merged when it enters its declared base branch. In a stacked
series, that base may be another feature branch rather than `main`.

```text
GitHub state MERGED
  + merge commit is ancestor of origin/main  = landed on main
  + merge commit is not ancestor of main     = stack-internal only
```

This distinction is currently material in both repositories. A stack-internal
merge is useful review progress, but it is not shipped source and must not be
reported as live behavior.

## 2. Executive Summary

OAS is becoming a smaller public SDK backed by a stronger private execution
core:

- explicit typed provider/model/runtime selection;
- provider-native reasoning, tools, multimodal values, and context capacity;
- no product governance, implicit execution limits, automatic compaction, or
  hidden retry policy;
- one canonical finite `Agent.run` execution history with crash fencing;
- a generic typed asynchronous accept/reconcile/cancel/observe façade whose
  long-lived backend and worker policy may be injected by the application;
- a simple Builder/Agent surface that does not expose WAL or reconciliation
  machinery to ordinary users.

MASC is changing from overlapping global loops, heuristic gates, elapsed-time
classification, and lossy checkpoint mutation into:

- one independent durable operation lane per Keeper;
- a flat external-effect Gate with exact Always Allowed, LLM Auto Judge, and
  nonblocking HITL;
- typed `Any`, `Any[]`, and `AsyncAny[]` composition over Tool, Model, Agent,
  Keeper, Fusion, Connector, and Scheduler adapters;
- MASC-owned LLM compaction, Memory, reinjection, and product continuation;
- structure-preserving dashboard projection of both MASC operations and
  subordinate OAS finite runs, with any retention gap rendered explicitly.

The large OAS execution diff is not a return of Keeper governance. It is the
private implementation cost of making one finite Agent run structurally exact
and crash-auditable. The adversarial concern is delivery size and migration
discipline, not the MASC/OAS dependency direction.

## 3. OAS: What Was Removed

### 3.1 Product governance and semantic heuristics

OAS #2590 is on `main`. It removed approval/policy modules, risk levels,
command/tool-name classifiers, hard-forbidden decisions, synchronous
guardrails, implicit recovery judges, automatic context reduction, automatic
retry/backoff, ambient provider/model defaults, synthetic success, and related
compatibility surfaces.

Why:

- OAS cannot know Keeper, Task, Board, Connector, or product authorization;
- fixed risk and command classifications were local opinions, not objective
  facts;
- implicit policy made a generic Agent SDK complex and stopped downstream
  Keepers;
- failures and configuration must stay typed instead of being repaired
  silently.

### 3.2 Implicit lifecycle limits

OAS #2589 is on `main`. It removed parallel timeout construction and preserved
only the explicit request-level streaming idle timeout. Omission remains
disabled; OAS does not invent 60/300/600-second defaults.

Turn, idle-turn, tool-round, cost, and token counters were already removed by
#2590. They remain observations, not termination authority.

### 3.3 Context reducer contracts

OAS #2603 is on `main`. It deleted design authority for `Context_reducer`,
forced pre-send compaction, token-estimate budget reduction, synthetic
ToolResult insertion, and orphan-result rewriting.

OAS now reports typed provider capacity/overflow. MASC decides when and how to
compact a Keeper checkpoint with an LLM.

## 4. OAS: What Is Being Upgraded

### 4.1 Provider and model truth

The embedded catalog and typed provider binding replace endpoint/model-name
inference. Capability, reasoning dialect, request shape, credentials, and
fallback order come from declared configuration.

OAS #2623 and #2624 are on `main`: the contract and Anthropic transport expose
provider-native input-token counting without estimates. MASC does not yet use
that count to prove a compacted full request fits the selected runtime.

`v0.215.0` adds exact `WithExecutionEnv` Tool occurrence and binds recursive
work to the exact Tool attempt. MASC pins release SHA `a7ea83fbbf`; later OAS
main commits are not silently treated as part of that release.

### 4.2 Typed image and audio providers

Typed catalog-driven Image and Audio provider work through #2612, #2615, and
#2629 is on OAS `main`. It belongs in OAS because provider wire contracts and
model capabilities are generic. MASC still owns Keeper tools, durable product
operations, and dashboard blocks that consume those capabilities.

### 4.3 One finite-run execution SSOT

Target:

```text
Execution Journal = sole execution writer and recovery SSOT
Event_bus          = volatile post-commit notification projection
Raw_trace          = read/export diagnostic projection
Durable_event      = deleted
```

The private execution topology is:

```text
Agent_run
  -> Agent_turn
    -> Provider_attempt
      -> structured Output_block
      -> Tool_invocation
        -> Tool_attempt
        -> nested child Agent_run
```

The reducer now binds child work to the exact Tool attempt (#2637) and #2640
pins flattened-recursion rejection. Exact occurrence propagation through the
remaining lifecycle hooks/events is still open in OAS #2642. Typed
`PreTool`/`PostTool` closure and the production single-writer cut remain before
the normative hierarchy is complete. Keeper/Fusion/MASC node kinds never enter
OAS.

Every scope admits one top-level Agent run, owns one logical sequence, and
closes at lifecycle completion. Store directory, application switch, and CPU
allocation policy are caller-owned. One opaque `Execution_runtime` encapsulates
the raw shared pool under that switch; ordinary callers and codecs never receive
the pool directly. No Keeper, Gate, Task, or MASC type appears in this layer.

| Private module | Exact responsibility |
|---|---|
| `Execution_event` | immutable topology, typed IDs, blocks, attempts, outcomes |
| `Execution_journal` | semantic reducer, invariants, one mutation authority |
| `Execution_event_store` | WAL bytes, commit authority, cursor, recovery |
| `Execution_lane_writer` | one run-local async durability actor |
| `Execution_runtime` | caller-sized application-lifetime CPU executor |
| `Execution_codec_executor` | canonical encode/decode/compare off Eio domains |

`Execution_lane_writer` is not the MASC Keeper lane. Its wake only reconciles a
run-local `Commit_outcome_unknown`; it does not schedule product work.

## 5. OAS Execution Stack: Current Truth

| Surface | Current reachability | Verdict |
|---|---|---|
| `v0.215.0` / #2639 | published and pinned by MASC | KEEP exact occurrence/attempt foundation |
| #2640 | OAS `main`, after release | KEEP recursion fence; not in MASC pin |
| #2642 | ready, mergeable; OCaml 5.4.1 job cancelled | REVIEW exact invocation propagation and obtain a non-cancelled full matrix; no MASC semantics |
| #2643 | Draft design | REVIEW recursive executable contract against the normative Goal |
| `Durable_event` / `Journal_bridge` | live public and production callers remain | KILL in the activation hard cut |
| independent `Raw_trace.record_*` | live writer in `agent_trace` | KILL writer; keep cursor-backed projection only |

Journal/store/lane-writer/codec foundations are now on `main`, but foundation
is not activation. Production still writes overlapping histories. The next OAS
execution slice must wire one Journal writer while deleting the old writers and
public selection surface in the same cut.

## 6. OAS Single-Writer Hard Cut

Current production execution facts are independently authored by
`Durable_event`, `Raw_trace`, Event_bus publication, hooks, and checkpoints.
The replacement cannot add a fifth writer.

During the live cut:

- route Agent/provider/tool occurrence creation only through the new Journal;
- persist Tool attempt before effect and exact receipt after effect;
- retain typed `Effect_outcome_unknown`; never claim universal exactly-once;
- delete `Durable_event`, `Journal_bridge`, `Agent.options.journal`,
  `Builder.with_journal`, auto-dump/save APIs, and direct append call sites;
- stop independent `Raw_trace.record_*` execution writes;
- derive Raw_trace queries/exports and Event_bus notifications from committed
  Journal cursors;
- delete old writer tests and do not retain a dual-write adapter.

Projection failure cannot change a Journal commit.

## 7. MASC: What Has Landed on `main`

Verified main-reachable changes include:

- #24765/#24766/#24769: remove shadow and heuristic autonomous executor loops;
- #24799: delete the health participation gate;
- #24800/#24806: remove circuit-breaker execution authority and retain
  observations;
- #24813/#24814/#24815: delete zombie cleanup/backend/protocol contracts;
- #24820/#24822: remove elapsed-time execution/zombie classification;
- #24821: delete Connector transport breaker authority;
- #24850: remove heartbeat cadence ceiling;
- #24851: remove the silent `[3, 300]` timeout clamp;
- #24889: delete the dead turn execution-budget module and its legacy tests;
- #24828/#24837: delete dead inference and handover timeout trigger surfaces;
- #24788: hard-cut duplicate mention authority;
- #24840: restore manual compaction lane proof without reintroducing automatic
  semantic compaction;
- #24727: remove the public heuristic compaction facade;
- #24810: recover Auto Judge backlog without globally blocking Keepers;
- #24856: remove fixed checkpoint ToolResult count/byte caps;
- #24868 and later pin slices: reach the current OAS `v0.215.0` release;
- #24879: begin Board observation from the exact origin boundary.
- #24961: remove the Fusion provider panel cap;
- #25001: delete time-window Keeper queue dedup;
- #25009: name the OAS `WithExecutionEnv` boundary exactly;
- #25022: surface exact OAS Tool occurrence in MASC;
- #24836: scope Gate retry lookup to one workspace;
- #24907: extract typed compaction evidence without changing compaction authority.
- #24957: carry exact OAS Tool invocation identity through the MCP boundary;
- #24968: remove zombie Fusion concurrency settings;
- #24964: remove title-based Task dedup admission.

Why these were removed: elapsed age, retry count, budget, health score,
circuit state, and arbitrary caps were being used as execution authority.
They caused pause, eviction, truncation, or global coupling without proving a
domain fact.

## 8. MASC: Open or Local, Not Yet on `main`

| Work | Current truth | Missing proof |
|---|---|---|
| #25018 | Draft, rebased to `fd70c8fc7f`, current CI running | merge exact settlement source index after fresh green |
| #24971 | Draft, mergeable, full CI green | merge exact private JSONL cursor |
| #25026 | Draft stacked on #24971, lightweight green | retarget after parent and run full CI |
| canonical settlement receipt leaf | local, 218 changed lines; latest-main rebase and format/static checks clean | focused build after the external bare Dune build, then Draft PR |
| settlement WAL | rejected generic prototype only | canonical State receipt, cursor replay, commit/checkpoint outcome |
| structural compaction leaf | local, 399 changed lines; hostile code findings repaired; focused build and 40 direct cases green | typed durable Tool continuation authority, then two-stage no-dispatch/closed-dispatch proof |
| per-Keeper Auto Judge drain | local, 396 changed lines; latest-main rebase clean | focused build after the external bare Dune build and a separate monotonic durable FIFO sequence leaf |
| #25019 | Draft, chat-admission slice; CI running | not a durable compaction operation or fit proof |
| #24993 | conflicting and red | supersede; do not use as current compaction proof |
| #24994 | Draft, green typed terminal leaf | re-evaluate after clean replacement stack |

The removal work is live, but the replacement durability is not. A green
foundation, local commit, or stack-internal merge is not production behavior.

## 9. MASC Target Composition

```text
Producer
  -> MASC owner operation journal
  -> external effect Gate when required
  -> finite OAS Agent.run / Tool invocation
  -> OAS receipt or typed unknown
  -> MASC wait, reconciliation, join, or next work
  -> owner-only Keeper wake
```

| MASC responsibility | Primary implementation area |
|---|---|
| owner queue and fencing | `keeper_runtime/keeper_event_queue*` |
| async durable request | `keeper/keeper_msg_async*` |
| exact current work projection | `keeper/keeper_current_operations*` |
| Gate and HITL | `keeper_gate*`, `keeper_approval_queue*`, `hitl_summary_worker*` |
| structural compaction | `keeper_compaction_unit*`, `keeper_compact_policy*` |
| LLM compaction | `keeper_compaction_llm_summarizer*`, `keeper_manual_compaction*` |
| Before/After evidence | `keeper_compact_audit*` and dashboard adapters |
| Memory and Artifact | durable Memory work plus content-addressed Artifact store |
| child joins | Scheduler/Connector/Fusion adapters over the same operation law |

MASC stores an opaque typed reference to the subordinate OAS scope. It does not
rewrite OAS run history. OAS does not decide when the Keeper resumes.
For `AsyncAny[]`, OAS owns the generic protocol façade while the injected MASC
backend remains the sole writer for the long-lived product operation namespace,
claim policy, and owner wake.

## 10. Remaining Critical Path

1. complete settlement source identity, canonical receipt, exact cursor, WAL
   commit/recovery, and checkpoint outcome;
2. activate the OAS execution Journal as sole writer and delete
   `Durable_event`, `Journal_bridge`, and independent Raw_trace writes;
3. preserve closed structural compaction units and exact open Tool/progress
   suffix through real provider dispatch;
4. count the full next request with provider-native truth and run durable LLM
   compaction waves until it fits, without an attempt cap or truncation;
5. move compaction to a source-CAS durable operation that releases and wakes
   only its Keeper lane;
6. replace Auto Judge global admission with per-Keeper owner drain and a
   monotonic durable FIFO sequence;
7. replace volatile/drop Memory and Artifact heuristics with durable owner
   work and exact identity;
8. compose Model, Agent, Keeper, Tool, Fusion, Connector, Scheduler, `Any`,
   `Any[]`, and `AsyncAny[]` under one typed operation law;
9. prove Task LLM verification, Scheduler fresh Gate/iCalendar semantics,
   multi-Connector origin, Fusion joins, and causal dashboard projection;
10. run mixed-lane restart and 48-hour live evidence, then delete stale code,
    tests, environment knobs, and current docs.

The next companion document is the exact purge manifest. It must distinguish
true Keeper execution constraints from legitimate transport page sizes,
explicit caller deadlines, test/eval budgets, and bounded shutdown cleanup.

Exact deletion and replacement contract:
[`KEEPER-FULL-FEATURE-PURGE-MANIFEST.md`](KEEPER-FULL-FEATURE-PURGE-MANIFEST.md).
