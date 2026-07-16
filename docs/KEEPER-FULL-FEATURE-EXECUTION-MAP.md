# Keeper Full-Feature Execution Map — OAS and MASC

> Status: live implementation checkpoint, not normative architecture
> Normative contract: [`KEEPER-FULL-FEATURE-GOAL.md`](KEEPER-FULL-FEATURE-GOAL.md)
> Checked: 2026-07-16 20:51 KST
> MASC `origin/main`: `dbf140cbdc`
> OAS `origin/main`: `3a6c92c715`
> Latest published OAS: `v0.213.0` at `e43baf8fe`

This document explains why both repositories are changing, what is already on
`main`, what exists only inside a stacked branch, and where the remaining work
belongs. Refresh every live fact before acting.

[근거] `git fetch origin --prune`, `git rev-parse origin/main`,
`gh pr view/list/checks`, and commit ancestry checks with
`git merge-base --is-ancestor`; checked 2026-07-16 20:51 KST; confidence High.

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
- lossless dashboard projection of both MASC operations and subordinate OAS
  finite runs.

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

OAS #2623 is on `main`: it adds a typed provider-native input-token count
contract without estimates. OAS #2624 adds Anthropic transport, but is currently
conflicting, non-Draft, and not on `main`; it needs rebase, review fixes, and
full CI.

`v0.213.0` predates #2589 and #2623. MASC's current `v0.213.0` pin therefore
contains typed overflow/JSON boundary work but not those two later commits.
OAS #2625 proposes `v0.214.0`; it is a release operation, not execution-stack
completion.

### 4.2 Typed image and audio providers

OAS #2610 -> #2612 -> #2614 -> #2615 is a separate Draft stack for typed
catalog-driven Image and Audio generation. It belongs in OAS because provider
wire contracts and model capabilities are generic. MASC later exposes those
capabilities as Keeper tools and dashboard blocks.

This stack is valuable but must not block Gate, Lane, or compaction completion.

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

The diagram above is current stacked shape, not the complete target hierarchy.
The current reducer permits `Tool_invocation -> Tool_attempt` and separately
parents a nested child `Agent_run` directly to `Tool_invocation`. It has no
typed `PreTool`/`PostTool` closure and cannot parent a child Tool invocation or
Agent run to the exact Tool attempt that created it. That would merge child
history across retries and cannot represent recursive Tool/collection
composition losslessly. Before production wiring, the reducer and projections
must implement the hierarchy in the normative Goal without adding
Keeper/Fusion/MASC node kinds to OAS.

Every scope admits one top-level Agent run, owns one logical sequence, and
closes at lifecycle completion. Store directory, switch, and shared CPU
executor are caller-owned. No Keeper, Gate, Task, or MASC type appears in this
layer.

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

| PR | Current reachability | Verdict |
|---|---|---|
| #2608, 5,154 changed lines | Draft, behind `main`, full CI green, not on main | KEEP architecture; update and re-review |
| #2611, 7,884 changed lines relative parent | non-Draft, stacked on #2608, not on main | return Draft; current-head full CI required |
| #2618 | merged into #2611's feature branch, not `main` | KEEP run-local writer; not shipped |
| #2622, 1,989 changed lines | Draft, stacked on #2611, lightweight checks only | KEEP/HOLD; body and full proof are stale |

The cumulative #2608 -> #2611 -> #2622 diff is about 13,741 additions across 67
files. That size is not proof of a wrong boundary, but it makes review and
landing risk high. Before production wiring:

1. restore Draft discipline and current-head CI;
2. resolve reviews against the real Eio 1.3 `Mutex.use_ro` contract;
3. add typed PreTool/attempt/PostTool, exact attempt-owned child edges,
   receipt, and unknown-outcome semantics;
4. prove the normal public Agent API stays simple;
5. wire the new Journal and delete old writers in one hard cut.

Private and unwired means the stack currently changes no production Agent
behavior.

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
- #24828/#24837: delete dead inference and handover timeout trigger surfaces;
- #24788: hard-cut duplicate mention authority;
- #24840: restore manual compaction lane proof without reintroducing automatic
  semantic compaction;
- #24727: remove the public heuristic compaction facade;
- #24810: recover Auto Judge backlog without globally blocking Keepers;
- #24856: remove fixed checkpoint ToolResult count/byte caps;
- #24868: pin OAS `v0.213.0` for typed overflow and JSON boundaries;
- #24879: begin Board observation from the exact origin boundary.

Why these were removed: elapsed age, retry count, budget, health score,
circuit state, and arbitrary caps were being used as execution authority.
They caused pause, eviction, truncation, or global coupling without proving a
domain fact.

## 8. MASC: Stack-Internal or Draft, Not Yet on `main`

| Work | Current truth | Missing proof |
|---|---|---|
| #24857 -> #24860 -> #24862 -> #24859 | merged only through feature bases | land semantic-sanitizer purge, structural units, operation projection on main |
| #24737 | merged into a Memory feature base only | durable Memory owner drain is not on main |
| #24873 | Draft, main-based, 398 lines, full CI green | production consumer and restart execution |
| #24875 | Draft, main-based, 399 lines, Build running | durable compaction operation, source CAS, reinjection |
| #24876 | Draft root, currently conflicting | rebase the Gate stack root |
| #24877 -> #24880 -> #24883 | clean/green stacked children | parent landing; per-item Judge start/terminal report |

This is why the product is substantially less constrained than 48 hours ago
but not yet “100% full feature.” Much deletion is live; the replacement durable
composition is still partly foundation or feature-branch-only.

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

## 10. Remaining Critical Path

1. land or restack feature-branch-only MASC deletion/foundation commits;
2. finish the OAS finite-run attempt/receipt contract;
3. perform the OAS single-writer hard cut and release it;
4. pin that release in MASC;
5. persist MASC operation-to-OAS run/node/receipt references;
6. make progress, waiting, wake, and restart reconciliation durable per Keeper;
7. make compaction a durable lane operation with exact source CAS;
8. hard-cut ToolResult externalization/hydration and legacy Memory heuristics;
9. wire Scheduler, Connector, Fusion, and typed Model/Agent/Keeper/Tool
   collection adapters without exposing MASC concepts through OAS;
10. prove mixed multi-Keeper restart, Gate, compaction, and dashboard causality;
11. delete obsolete implementation, tests, environment knobs, and current docs.

The next companion document is the exact purge manifest. It must distinguish
true Keeper execution constraints from legitimate transport page sizes,
explicit caller deadlines, test/eval budgets, and bounded shutdown cleanup.
