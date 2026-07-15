---
title: "RFC-0000 — MASC × OAS Master Roadmap"
date: 2026-07-15
lang: ko
---

> Status: **Active / canonical design source**<br>
> Scope: MASC and its one-way OAS dependency<br>
> Generated HTML is a projection. Edit this Markdown, never the generated HTML.<br>
> Evidence snapshot: `origin/main@c823ab3f78c3dca11a3bec0dad0de874b58a9ab2`, checked 2026-07-15 KST.

## 0. Document authority

This document is the design and execution-order SSOT for the MASC × OAS boundary. Older RFCs and audit reports remain evidence and history; when they conflict with this document, they are not active requirements.

Normative statements use **MUST**, **MUST NOT**, and **MAY**. An As-Is claim is only a dated evidence snapshot and must be reverified against the current head before implementation. A goal is complete only when typed behavior, persistence truth, CI, and live runtime evidence agree. A log line, dashboard projection, grep count, or generated HTML alone cannot prove runtime correctness.

The current dependency pin is owned by `scripts/oas-agent-sdk-pin.sh`; package manifests and lockfiles are validated projections. This document does not duplicate a mutable version as policy.

## 1. North Star

MASC is a multi-agent collaboration product whose Keepers live continuously, retain place and relationship context, and progress through Board, Goal, Task, Job, Channel, Connector, Gate, Tool, Fusion, Memory, Runtime, Provider, and Model abstractions. Product-specific integrations are adapters around those abstractions, not vocabulary embedded in the runtime core.

OAS is a general OCaml Agent SDK. It makes provider/model calls and agent execution simple for any consumer. MASC knows OAS; OAS never knows MASC.

### 1.1 Runtime laws

| Law | Normative rule |
|---|---|
| **Activity first** | Cost, token, turn, idle-turn, tool-round, approval wait, provider failure, or pending work MUST NOT terminate or globally pause a Keeper. A Keeper waiting for one activity continues other admissible work. Only explicit operator stop, process shutdown, or unrecoverable invariant/storage corruption may stop the affected scope. |
| **Lane per Keeper** | Each Keeper owns an ordered logical lane. Domain events, async completions, maintenance, and resumes wake only the owning lane. One lane failure MUST NOT pause the fleet. A lane is logical continuity, not an immortal fiber. |
| **Semantic judgment belongs to an LLM** | Relevance, completion, delegation, compaction content, memory retention/forgetting, and whether a proposed action is appropriate are LLM decisions expressed as schema-valid typed receipts. String matching, risk scores, counters, or magic thresholds MUST NOT make those decisions. |
| **Mechanics are deterministic** | Identity, ownership, routing, persistence, deduplication, compare-and-swap, schema validation, resource scope, and receipt settlement are typed deterministic mechanics. Sending these mechanics to an LLM would weaken durability rather than improve judgment. |
| **Everything is observed** | Every turn, model/provider attempt, token/cache/cost measurement, tool call, gate decision, async receipt, compaction, memory operation, and error carries causal identifiers. The durable journal is recovery truth; logs, OTel, and dashboard are projections. |
| **Hard cut** | Once a replacement invariant is proven, legacy types, branches, configuration, environment variables, tests, and documents are removed. Compatibility shims, dual writes, and dormant consumers are not long-term migration strategy. |
| **No product leakage** | Core code MUST speak abstract product vocabulary. GitHub, Discord, Slack, browser vendors, credential products, model vendors, and concrete CLI names belong to Connector, Tool, Provider, or configuration adapters. |

### 1.2 Judgment boundary

The LLM decides **meaning**. Typed code makes the decision recoverable and enforceable.

```text
observation or request
  -> typed candidate/context construction       deterministic
  -> schema-valid LLM judgment                  nondeterministic meaning
  -> typed invariant/resource validation        deterministic
  -> durable commit or explicit rejection       deterministic
  -> owning-lane wake and observable receipt    deterministic
```

LLM unavailability yields a typed `PendingJudgment` or `Inconclusive` for that request. It never creates a permissive fallback and never blocks unrelated work.

## 2. Boundary law

```text
external product adapters
          |
          v
MASC: collaboration, Keeper lanes, judgment, durable jobs
          |
          v
OAS: generic agent/provider/model execution library

OAS -X-> MASC vocabulary or policy
```

| Owner | Owns | MUST NOT own |
|---|---|---|
| **OAS** | Immutable provider/model request, typed capability catalog, streaming/tool-call representation, generic agent lifecycle primitives, typed errors, lossless transcript/checkpoint primitive, typed provider context-overflow signal | Keeper, Board, Goal, Task, Channel, Gate/HITL, Scheduler, Connector, Fusion, MASC Memory, compaction policy, approval orchestration, product credentials, ambient catalog discovery, hidden execution budgets |
| **MASC** | Keeper identity and lane, collaboration state, explicit Runtime assignment, LLM judgment boundaries, durable async jobs, compaction, Memory, Gate/HITL, Scheduler, Connector, Fusion, Board, Goal/Task, dashboard projections | Provider-wire heuristics, vendor-specific SDK behavior duplicated from OAS |
| **Adapter/configuration** | Concrete external service, credential acquisition, endpoint, repository/server/channel mapping, browser or media backend | New MASC/OAS core semantics |

OAS MUST remain easy to call. It must not require a downstream user to construct MASC policy objects or understand MASC lifecycle state. Context compaction is not an OAS feature: OAS reports overflow and preserves lossless input; MASC decides and performs compaction.

Unknown provider/model capability is a typed unknown capability, not a guessed permissive preset. That failed request remains visible while the Keeper continues other work.

## 3. Subsystem contracts

### 3.1 Keeper and lane

A Keeper has one ordered logical timeline containing Board, Goal, Task, Job, Connector, Gate, Tool, Fusion, Memory, and chat activity. The lane serializes state commits, not all external waiting.

- An external or long-running call returns a `DurableRunRef`; the turn slot is released while it runs.
- `Partial`, `Question`, `Final`, and `Failed` receipts are persisted and wake only the owning Keeper.
- A non-yielding in-process fiber can occupy an Eio domain and stall unrelated work. It is not “harmless because lanes are isolated”; cooperative yield, process isolation, or a typed external-attempt lease must be demonstrated for the actual backend.
- Busy input is durably queued. A configured acknowledgement is a separate LLM-authored activity, never a hardcoded sentence.
- Before a leased stimulus is acknowledged, the same stimulus remains pending/requeued or a typed successor is durably committed. `Ack` without successor is forbidden.
- Restart recovers queued, running, prepared, and completed jobs without silently dropping `Running` state.
- A self-call cannot poll while holding its own lane slot. It submits work, releases the slot, and resumes from a receipt.

### 3.2 Tool, capability, and generic invocation

The generic execution vocabulary is:

```text
ToolRef
CapabilityRef
ExecutionEnvironmentRef
CredentialRef
InvocationTarget = Model | Agent | Keeper | Tool
InvocationGraph = One | Sequence(nonempty) | Parallel(nonempty)
                | Reduce(items=nonempty, reducer)
InvocationRequest
DurableRunRef
ContinuationRef
RunReceipt = Accepted | Partial | Question | Final | Failed
```

- A Tool declares typed input/output schema and required capabilities. Core code does not branch on tool names such as `gh`, `curl`, or a vendor product.
- Capability is a positive compatibility fact only. It is not authorization, risk, priority, or a quality score. `Money`, `Credential`, `Destructive`, product identity, and command substrings are not capabilities.
- Filesystem base path, sandbox handle, network handle, browser/vision/image/audio capability, `CredentialRef`, and opaque `principal_ref` are explicit execution-environment inputs. Secret material is resolved only inside the leaf adapter and is never serialized into a Run, Gate record, journal, or LLM prompt.
- Tool arrays and heterogeneous arrays are explicit acyclic `InvocationGraph` values using the same execution/receipt contract as a single target. Numeric scale changes graph size, not semantics.
- Backpressure reports capacity state and queues work; it is not a semantic max-turn/max-tool/max-agent gate.
- Target intent may be chosen by an LLM. Deterministic code resolves the exact typed target and validates its declared capabilities.
- Submission returns only after durable `Accepted`; receipts carry stable run/node/receipt identity and monotonic sequence, with exactly one terminal `Final` or `Failed` receipt.
- `ContinuationRef` is a product-neutral durable reference to the caller lane and expected receipt. It is not a Connector-specific closed sum or an in-memory callback.
- Runtime does not infer parallel safety from `read_only`, guessed resource keys, tool names, or deadlines. Ambiguous composition is a typed unsupported graph that the Keeper/LLM may revise.
- Graph validation deterministically rejects empty nodes, cycles, invalid reducer edges, and incompatible declared capabilities. It does not guess a topology.
- Every failed or abandoned run has a typed durable receipt. Orphan `Running` entries are never silently dropped.

### 3.3 Gate and HITL

There is one Gate abstraction, not a governance hierarchy.

- `Manual`, configured `AutoJudge`, and explicit scoped `AlwaysAllowed` are decision sources for an exact `PendingGateRequest` created by the committing leaf adapter.
- Gate is attached to the leaf adapter that will commit an external operation. Generic invocation and Scheduler do not construct a universal effect IR or central effect classifier.
- No `R0/R1/R2/Rx`, `risk_class`, `hard_forbidden`, effect bucket, keyword classifier, or hidden deny ladder may be introduced.
- Gate routing is explicit Tool/Runtime configuration, not inference from a command string, URL, filename, or product identity.
- `AlwaysAllowed` is versioned, revocable, and explicitly scoped to subject, operation reference, schema revision, execution-scope reference, and normalized input constraint. Capability is not authorization and is not part of a grant. A rule is never inferred from a previous digest or scheduled occurrence.
- A pending Gate decision blocks only that request. The Keeper lane continues unrelated admissible activities.
- The deterministic boundary seals request identity, exact arguments, preconditions, resource scope, and decision receipt before execution. This is correctness, not a risk heuristic.
- Credential secrets never enter an LLM prompt or Gate receipt. When authority scope must be referenced, the adapter supplies an opaque `principal_ref`.
- Auto Judge failure stays pending/retryable through a durable dispatcher. It does not wait for another incidental Gate call or Keeper restart.
- Gate persistence does not hold a global mutex across file or network I/O; ownership-scoped serialization and immutable snapshots prevent cross-lane stalls.

### 3.4 Scheduler

Scheduler emits durable typed occurrences; it does not directly execute Board, Connector, Tool, or product-specific effects.

```text
schedule definition
  -> occurrence(schedule_id, due_at, stable occurrence_id, payload)
  -> durable owning-lane enqueue
  -> Keeper/LLM decides the activity
  -> typed settlement
```

- Recurring schedules are first-class. Legacy direct recurring actions and standing approval grants are deleted.
- `Schedule_store` is the sole recurrence SSOT. A second Keeper recurring registry, JSON file, or heartbeat recurrence path is forbidden.
- An occurrence contains the target Keeper and immutable instruction/artifact references, not a product action to execute.
- Delivery is durable at-least-once with stable occurrence identity and idempotent consumption, not “at-most-once plus retry.”
- Only `Enqueued` or `AlreadyPresent` is dispatch success. Storage failure is a typed retryable occurrence state and MUST NOT be recorded as `Succeeded`.
- A corrupt occurrence or failed target is isolated. Unrelated schedules and Keeper lanes continue.
- Clock comparison and declared typed conditions are deterministic. A semantic condition is evaluated by an LLM and recorded as a typed judgment.

### 3.5 Connector and Channel

Connector is an adapter registry, not a fixed enumeration of external products.

- An inbound event preserves exact connector, workspace/server, channel/thread, actor, message, and attachment identity.
- Each space has isolated conversational context. Identity can link a person across events without collapsing different spaces into one context.
- Inbound events are persisted before the owning lane is notified.
- Busy delivery is queued; optional acknowledgement and later answer are LLM-authored activities with independent receipts.
- Outbound delivery failure is explicit and retryable. It cannot be presented as a successful reply.
- Concrete credential and repository/channel mapping lives in Connector configuration or plugin code, never MASC/OAS core.
- Adding an adapter does not add a product-specific variant to the core Connector or continuation types.
- Unknown adapters or unresolved continuations yield typed `UnsupportedConnector` or `UnroutableContinuation`; the durable inbound event/result remains unsettled and visible.

### 3.6 Board

Board supports Write, Edit, Comment, Like, Unlike, Emoji, rich text, attachments, and multimodal rendering.

- The event journal is append-only. Edit creates a revision; projections may show the latest revision without destroying history.
- Board is weakly coupled to Goal, Task, Gate, and Keeper through typed references/events only.
- Mention, relevance, “substantive update,” related-post discovery, and completion claims are LLM judgments.
- Storage validation, revision identity, attachment safety, and rendering fallback are deterministic.
- Rich editor/viewer behavior and image/audio/video/file/gallery projection are first-class deliverables, not deferred decoration.

### 3.7 Goal and Task

Goal and Task are distinct weakly coupled boundaries. A Goal may reference Tasks; neither owns the other’s lifecycle.

- Assignment and linkage use explicit opaque references.
- Related Board/Connector information becomes an LLM judgment candidate and may wake the owning Keeper.
- Completion, progress, stagnation, decomposition, and reprioritization are LLM judgments with typed evidence.
- A Goal or Task budget/counter never pauses a Keeper. Measurements remain telemetry.

### 3.8 Fusion

Fusion is a generic invocation composition over Model, Agent, Keeper, Tool, and heterogeneous targets. Judge-of-Judges is composition, not a special parallel runtime.

- Submission is nonblocking and immediately returns a durable run reference.
- Panel/Judge topology and semantic synthesis are LLM-authored typed plans; target resolution, schema validation, persistence, and settlement are deterministic.
- Fusion compiles its plan to the generic acyclic `InvocationGraph`; nested Fusion is allowed only when graph validation proves there is no cycle.
- No fixed panel, judge, wave, tool-call, turn, cost, or time budget is a correctness gate.
- Capacity backpressure queues work and remains observable.
- Restart recovers the run registry and completion wake route. A process-memory-only route is invalid.
- Partial, question, final, and failure receipts use the same contract as every other invocation.
- Board publication is an optional projection. Publication failure is distinct from Fusion deliberation outcome and cannot erase the result.

### 3.9 Memory

Memory and active-context compaction are separate subsystems. They may share Runtime assignment machinery but do not share store, trigger, receipt, or lifecycle.

- Memory stores typed episodes, claims, relations, source/place/time context, and forgetting decisions.
- Retain, promote, contradict, supersede, and forget are LLM librarian judgments. Counts, TTL, lexical match, graph distance, or scores may generate candidates but never decide.
- Compaction output is model-input context, not a Memory claim or domain-state transport.
- Memory cannot directly rewrite the active checkpoint; compaction cannot silently write long-term Memory.
- Supabase pgvector is the only vector backend. Qdrant is retired. Whether a memory path uses vector retrieval or structured retrieval is explicit, not contradictory “pgvector without vectors” wording.
- Deletion/forgetting produces a propagation receipt across every configured store and projection. Failure is explicit.

### 3.10 MASC-owned LLM compaction

Compaction is a durable owning-lane maintenance operation.

```text
ProviderOverflow | OperatorRequested | ConfiguredSemanticReview | LlmJudgedRequest
  -> ContextCompactionRequested(operation_id, keeper, source_lease,
                                base_checkpoint_revision, runtime_assignment)
  -> background LLM planning with typed candidate-attempt receipts
  -> owning Keeper Maintenance admission
  -> compare-and-swap checkpoint save

Saved      -> Applied -> exactly one resume stimulus -> next turn reinjects saved hash
StaleNoop  -> CheckpointSuperseded -> replan from latest revision
Error      -> explicit recoverable failure; never Applied or Completed
```

- Token, message, turn, ratio, cooldown, and cost measurements are observations, not compaction authorization.
- A configured review asks an LLM whether and how to compact; it is not a numeric auto-cutoff.
- Planning does not hold the Keeper turn slot. Other Keepers and other admissible work continue.
- `Overflowed` admits typed `Maintenance` work while rejecting ordinary checkpoint mutation. Only `Saved` returns the Keeper to normal execution.
- Candidate failover records attempted, failed, invalid-output, timed-out, and succeeded receipts. Exhaustion is a typed error.
- Compare-and-swap includes checkpoint revision/hash so unseen transcript tail cannot be overwritten.
- Reinjection is input-context restoration, not re-observation. Board, Connector, HITL, Goal, and Task events are not regenerated.
- Dashboard shows trigger, before/after hash, bytes/messages, candidate attempts, classified save result, and resumed turn ID from durable receipts.

### 3.11 Runtime, Provider, and Model

- Runtime configuration maps logical uses and Keeper assignments to typed provider/model candidates. The mutable pin/catalog SSOT stays in configuration and generated package locks, not duplicated prose.
- Provider/model capability is derived from typed catalog records. Host, URL, model-name substring, or vendor-name matching is forbidden.
- General Keeper turns and compaction may use separate Runtime assignments but share typed attempt receipts.
- Ordered fallback is explicit configuration. Every attempt is isolated and visible; exactly one successful attempt is committed.
- Sampling values are explicit optional configuration. `temperature=0` reduces sampling variance but is not a reproducibility guarantee and MUST NOT be synthesized as a hidden fallback.
- Provider/tool-local liveness timeout may fail one external attempt. It does not become a Keeper execution budget and does not acknowledge the originating stimulus without a durable successor.
- Cost, token, turn, latency, and Tok/s are aggregated telemetry only.

### 3.12 Dashboard and observation

- Dashboard chat renders interleaved text, thinking/reasoning, tool calls/results, partial/question/final receipts, images, audio, video, and other supported modalities in causal order.
- Every provider/tool attempt and every retry error is visible. “Show raw error only after retries are exhausted” is forbidden.
- Dashboard is a read model. It cannot manufacture success, lifecycle, settlement, or compaction state.
- Unknown, stale, unsupported, unavailable, authorization-missing, failed, and retrying states are distinct typed projections.
- Before/after compaction, gate decisions, async run state, queue lease/ack/requeue, Runtime candidate attempts, tokens, cost, and Tok/s are observable.

### 3.13 OAS internals

- OAS contains no MASC domain vocabulary and performs no semantic compaction or approval judgment.
- MASC consumes the OAS public typed contract directly. A breaking SDK release intentionally exposes every affected compile site; an `oas_compat` shim must not preserve old variants, defaults, parsers, or string error categories.
- OAS does not discover catalogs through ambient environment variables and does not synthesize hidden turn/tool/cost/token limits.
- Provider output is opaque semantic content to OAS; OAS performs typed parsing, validation, and transport only.
- Mutex choice is per critical section: use `Eio.Mutex` when the section may yield or block a fiber; a brief non-yielding in-memory section may use `Stdlib.Mutex`. “Eio mutex only” is not a rule.
- Production control flow returns typed errors and does not use `assert false`, silent catches, or permissive unknown fallbacks.

## 4. Forbidden legacy

The following concepts and their producers, consumers, configuration, environment variables, tests, and documentation are purge targets unless a current typed invariant explicitly requires them:

- `R0/R1/R2/Rx`, `risk_class`, `hard_forbidden`, `keeper_effect_request`, effect keyword buckets
- `max_turns`, `max_idle_turns`, `max_tool_rounds`, `budget_exhausted`, `Exec_budget`, turn/token/time terminal `Budget`
- unused Eval `max_turns`/`max_cost_usd`, Worker `timeout_sec`, proactive `max_attempts`, Fusion `max_tool_calls`/wave budgets, and string-classified `MASC_RESILIENCE` retry policy
- dead `TurnLimitObserved`, `ExecutionTimeoutObserved`, and `ExecutionIdleTimeoutObserved` success branches
- global pause/cancel caused by one Keeper, Connector, Gate, provider, schedule, or tool failure
- OAS `Context_reducer`, automatic truncation, automatic summarization, or OAS-owned compaction
- Scheduler direct product effects and inferred/standing grants
- product/vendor/CLI-specific branches in core, including GitHub App or repository credential logic
- hostname, base URL, path, command, or model-name string sniffing used as policy
- `read_only`, guessed resource keys, or deadline/attempt caps used to infer a generic invocation topology
- orphan `Running` drop, swallowed queue persistence errors, fake `Succeeded`, hidden retry errors
- arbitrary fixed cardinality/time thresholds used as runtime correctness gates
- `OneForAll`/`RestForOne` fleet supervision that violates Keeper-lane isolation
- Qdrant, compatibility dual-write, legacy field parsers, and ambient catalog environment variables

Tests whose sole purpose is to preserve a purged contract are deleted with that contract. Tests that prove the replacement invariant remain or are rewritten around the new typed behavior.

## 5. Execution roadmap

Each code PR proves one invariant and should normally remain below 400 changed lines. Mechanical generated artifacts and deletions are reported separately; line count is not a reason to create a compatibility layer.

| Stack | Deliverable | Exit evidence |
|---|---|---|
| **S0** | Canonicalize this RFC and reproducible HTML generation | Repository Markdown is canonical; generated HTML matches it; stale active-SSOT claims removed |
| **S1** | Hard-delete impossible execution-limit stop reasons and residual budget/config/env contracts | Production constructors and consumers are absent; normal completion cannot be confused with a limit |
| **S2** | Classified checkpoint save with revision/hash CAS | Only `Saved` becomes `Applied`; `StaleNoop` becomes `CheckpointSuperseded`; storage error never completes |
| **S3** | Provider overflow → durable compaction job → owning-lane maintenance → reinjection/resume | Candidate failover, restart recovery, unseen-tail interleaving, same-lane resume, and two-Keeper isolation tests pass |
| **S4** | Result-bearing Scheduler enqueue | Persistence failure cannot produce success; retry preserves occurrence identity; one durable wake remains |
| **S5** | Remove Scheduler direct effects and standing grants | Every occurrence reaches a Keeper lane; semantic action is LLM judged; no direct Board/Connector execution |
| **S6** | Generic Tool/Model/Agent/Keeper/ToolSet/Heterogeneous invocation contract | Durable run reference and partial/question/final/failure receipts share one executor/store/wake path |
| **S7** | Single nonhierarchical Gate with durable Auto Judge and scoped Always Allowed | No risk ladder/string classifier; pending request is local; retry survives restart |
| **S8** | Multi-Connector and Channel registry | Mixed connectors preserve exact space/actor context; busy queue and outbound failure are durable |
| **S9** | Board rich text/multimodal revisions and Goal/Task reactive judgment | All requested Board operations render; revisions are non-destructive; semantic wakes are LLM receipts |
| **S10** | Memory librarian and forgetting pipeline | Candidate generation is deterministic; retain/forget is LLM judged; compaction and Memory stores remain separate |
| **S11** | Fusion and generic composition restart recovery | Nested heterogeneous calls recover without orphan drop and wake only the owner |
| **S12** | Dashboard causal transcript and live As-Is/To-Be proof | UI matches durable journal; failures are not hidden; before/after compaction and async receipts are visible |

Capacity benchmarks follow structural correctness. Start with small mixed target types and multiple isolated Keepers on the real durable queue/dispatcher/receipt path. Counting isolated `Context.create_sync` objects does not prove Lane scale. Measure larger fleets later without turning measured cardinality into a semantic limit.

## 6. Required end-to-end proofs

1. Provider overflow creates one durable compaction request; the first model attempt fails, fallback succeeds, CAS saves, exactly one same-lane resume is enqueued, and the next turn reinjects the saved checkpoint.
2. A newer transcript tail committed during compaction produces `CheckpointSuperseded`; no unseen message is lost.
3. Restart at requested, planning, prepared, and saved phases recovers without duplicate apply or wake.
4. One Keeper waits for a Gate, provider, Tool, Fusion, or Connector while another Keeper and unrelated work in the same Keeper continue.
5. Provider timeout cannot acknowledge a Connector/Board/Goal stimulus without a pending copy or durable successor.
6. Scheduler persistence failure remains retryable with the same occurrence ID and cannot appear as `Succeeded`.
7. Model, Agent, Keeper, ToolSet, and heterogeneous nested calls emit the same typed receipt envelope and recover after restart.
8. Connector messages preserve connector/server/channel/thread/actor identity; two spaces never share accidental context.
9. Always Allowed applies only to its explicit scope; changed arguments or resources require a new decision without stopping the Keeper.
10. Dashboard reconstructs causal order from the journal and exposes every failed attempt, Gate decision, tool result, and compaction before/after state.

CI is authoritative for the full Dune build and test suite. Focused local checks use `scripts/dune-local.sh build <target>`. Live runtime proof is separate from CI and must use durable journal/API evidence; no fake green is accepted.

## 7. As-Is snapshot and To-Be delta

This table is evidence from the dated head in the document header, not timeless policy.

| Area | As-Is evidence | To-Be |
|---|---|---|
| Keeper lane | Per-Keeper supervision, turn admission, durable event queue, and lane-local wake exist | Unified durable receipt/successor rule; maintenance admission and restart recovery complete |
| HITL/Gate | Manual, Auto Judge, and Always Allow paths exist; risk-level production path was not found | Durable retry dispatcher, no global I/O lock stall, explicit scoped configuration only |
| Connector | Discord preserves detailed origin identity; other connectors are uneven | Registry-based mixed connectors with identical durable intake/outbound contract |
| Fusion | Background execution and completion wake exist | Generic composition contract, durable restart recovery, no process-memory wake dependency |
| Generic invocation | Planner/type fragments and special implementations exist | One production executor/store/receipt/wake path for all target kinds |
| Scheduler | Stable occurrence work is partial | No swallowed enqueue failure, no direct product effect, durable at-least-once delivery |
| Compaction | Manual MASC compaction and LLM summarizer exist; typed overflow does not drive the full lane path | Durable request, candidate receipts, classified CAS, same-lane reinjection/resume, dashboard proof |
| Execution limits | OAS hard limits were removed, but dead MASC variants/consumers and other budget residues remain | Hard-delete residues while retaining pure measurements and external-attempt liveness |

## 8. Review rules

A change is rejected when it:

- adds a string/regex/hostname/path/vendor heuristic for a semantic decision;
- collapses `Result`, unknown, stale, partial, or retryable state into success/`None`;
- adds a global lock, pause, or cancellation path for lane-local failure;
- adds a numeric runtime gate where observation or backpressure is sufficient;
- makes OAS know a MASC or external-product concept;
- makes a fiber stand in for a durable job;
- lets a projection become write/recovery truth;
- preserves a removed legacy contract only to keep its old test green.

Every review states the exact head, separates source/CI/live-runtime truth, and identifies whether the decision is LLM semantic judgment or deterministic mechanics.

## 9. References

These operational and historical inputs do not override this RFC. Revalidate them against the current code and the forbidden-legacy section before use.

- Deprecated command-plane history: `docs/COMMAND-PLANE-RUNBOOK.md`
- Existing benchmark operations: `docs/BENCHMARK-RUNBOOK.md`
- Existing supervisor operations: `docs/SUPERVISOR-MODE.md`
- OAS pin source: `scripts/oas-agent-sdk-pin.sh`
- OCaml version authority: `dune-project` and CI; OCaml 5.4 API reference: <https://ocaml.org/manual/5.4/index.html>
- Eio mutex guidance: <https://ocaml.org/p/eio/latest/doc/eio/Eio/Mutex/index.html>
