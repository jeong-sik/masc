# Keeper Autonomy Evidence Campaign — 2026-08-13

> Status: Active implementation campaign; no completion claim
>
> Goal authority: [KEEPER-FULL-FEATURE-GOAL.md](KEEPER-FULL-FEATURE-GOAL.md)
>
> This file is a dated execution snapshot. GitHub, CI artifacts, the deployed
> binary identity, runtime configuration, and durable runtime stores remain the
> authorities for their respective facts.

## Goal

Prove that each configured Keeper can continue autonomous work without losing
its owner identity, while every in-scope runtime/model can execute its declared
roles and tools through observable, durable, exactly-once boundaries. A green
source test is not a live pass, registration is not availability, and an old
receipt is not evidence for the currently deployed build.

The campaign completes only when every required matrix cell is either:

- `Passed` with all three independent evidence paths;
- `Unsupported` with a closed policy/capability reason; or
- removed from the required inventory by an explicit scope revision.

`Failed`, `Not_run`, `Blocked`, or missing evidence keeps the goal incomplete.

## Cell identity and verdict

Every cell has the stable identity:

```text
(runtime_id, model_id, role, capability, scenario, protocol,
 build_commit, config_revision)
```

Absence is `None`/JSON `null`; it is never replaced with `unknown_model`, an
inferred provider, the checkout HEAD, or a dashboard fallback.

```text
Passed(evidence_bundle)
Failed(failure_kind, evidence_refs)
Unsupported(typed_reason)
Not_run
Blocked(blocker_ref)
```

The strict campaign metric is:

```text
unresolved_required_cells = failed + not_run + blocked + missing_evidence
```

## Three required approaches for every case

Every execution case must be demonstrated in three different ways. None may
substitute for another.

1. **Hermetic contract** — closed variants, exhaustive pattern matching,
   strict codecs, deterministic reducers, and config/catalog resolution. This
   proves the implementation cannot create an invalid combination silently.
2. **Isolated controlled execution** — a unique `case_id`, deterministic
   fixture/private canary, exact effect receipt, negative case, and restart or
   replay where relevant. This proves the behavior at its execution boundary.
3. **Fleet observation** — durable journal/WAL/queue evidence correlated with
   API plus SSE/WebSocket/dashboard state. Browser cases retain a screenshot
   linked to the same receipt digest; screenshots are never the SSOT.

Hidden chain-of-thought is excluded from every path. Only typed reasoning
presence, counts, timing, kind, redaction state, event identity, and sequence
metadata may be retained or projected.

## Required matrix

The manifest generator expands every registered in-scope runtime/model across
a closed sum of valid requirements rather than a role × capability Cartesian
product.

| Area | Nominal cases | Adverse/recovery cases |
|---|---|---|
| Provider and role lanes | Keeper, verification, cross-verifier, librarian, HITL judge, board attention, compaction, Fusion panel/judge/meta-judge | provider rejection, cancellation |
| Autonomous continuity | autonomous turn | provider rejection, cancellation, restart/succession |
| DrainQueue | ordered owner queue | duplicate delivery, blocked head, restart recovery |
| Scheduler | occurrence dispatch and settlement | duplicate occurrence, restart recovery |
| Gate/HITL Auto Judge | approve | deny, defer, cancel, provider failure, one-shot settlement |
| Domain surfaces | Board/Comment, Task lifecycle, Goal lifecycle | invalid input, denied effect, receipt mismatch |
| Tool composition | serial, parallel, batch | invalid input, denied effect, dependent-order enforcement |
| Async tools | accept/observe/terminal | cancel, duplicate delivery, restart recovery |
| Sandbox | requested = effective = receipt | denied containment, mismatch before effect |
| Broadcast turn | owner delivery | duplicate delivery and replay |
| Stream/reasoning | identified ordered deltas | duplicate replay, reconnect/restart, hidden CoT withheld |

Required production scope is the configured Claude Code subscription, Codex
subscription, GLM Coding Plan, Kimi Coding Plan, and Ollama Cloud runtimes.
Locally discovered runtimes are optional canary targets: their absence never
fails the production campaign. Registration does not claim credentials,
health, completion, or capability support.

## SSOT and effect boundaries

- Agent Core Execution Journal is the sole writer for finite Agent execution.
- MASC owns long-lived Keeper, Gate, schedule, queue, domain, and Fusion state.
- Event bus, SSE, raw trace, metrics, and dashboard are post-commit projections.
- DrainQueue means the durable owner queue; a turn-scoped volatile event-bus
  drain is a different operation and must not be used as proof.
- Pure code returns a typed command or verdict. Filesystem, network, process,
  Docker, browser, and external-tool effects run at the outer shell.
- Unknown, ambiguous, corrupt, or outcome-unknown state fails closed and remains
  observable. It is never converted to a blind retry.

## Dashboard acceptance

For every capability slice, completion requires all three layers:

1. strict backend/API codec with receipt correlation;
2. component/reducer transition and replay tests;
3. stateful browser canary proving API, transport, and DOM agree.

Overview, top-bar attention, Keeper detail, Runtime, Schedule, Gate,
Verification, Fusion, Observatory, and Internal Agents must derive status from
the same backend fact. A screen must not display healthy while the composite
health verdict requires operator action.

Browser automation must preflight the effective MASC root, deployed binary
commit, config revision, and private canary scope. Merely opening a read-only
screen must not create product state. Screenshots go under ignored temporary
artifacts and reference the correlated API/transport evidence digest.

## Small PR graph snapshot

All listed implementation PRs are Draft unless GitHub says otherwise. Stacks
exist only where a schema or execution contract is a real dependency.

```text
Capability proof
#28545 identity
  -> #28547 three-path verdict
       -> #28549 strict completion metric
            -> #28571 baseline manifest
                 -> #28573 registered-runtime adapter
       -> #28553 strict case JSON codec

Execution Journal
#28546 Runtime_agent store threading
  -> #28554 root Eio owner
       -> #28567 stable operation identity
            -> #28568 durable locator lifecycle
                 -> #28569 exact API-boundary dispatch

Runtime/model probe
#28560 typed completion-probe result

Sandbox
#28562 requested/effective/receipt contract
  -> #28572 effect-boundary admission and receipt wiring

Reasoning and stream
#28561 raw-trace reasoning withholding
  -> #28563 trajectory closed withheld-content sum
#28558 dashboard never requests hidden CoT
#28556 stream replay dedupe by event identity

Independent observability and recovery slices
#28548 configured proactive truth and live drift
#28559 composite health shared by Overview and top bar
#28565 long durable-queue FIFO/restart property
#28570 closed SSE registry and bidirectional parity
```

The one-line main-suite repair was merged independently as #28540. Duplicate
#28564 was closed rather than preserving a second copy of the same change.

## Current live baseline, not a verdict

The 2026-08-13 read-only observation used `/health?full=1` and the effective
runtime root reported by that endpoint. At that observation:

- eight Keepers were bootable and seven executable;
- the composite health status was degraded and required operator action;
- Kimi authorization failed for the recovering analyst lane;
- durable reaction rows were stale;
- rtprobe's configured proactive state disagreed with a dashboard projection;
- Docker-requested Keepers had local/inherit effective receipt evidence;
- the deployed binary git commit was unproven;
- current Fusion/Judge-of-Judges, async, batch, and broadcast proof was absent;
- raw reasoning text was still persisted by legacy diagnostic paths.

These facts may change. They remain failures or unproved cells until a deployed
exact-build canary produces the three correlated evidence paths.

## Bottom-up completion order

1. Merge current-only leaf contracts and codecs.
2. Rebase and merge their true stacked consumers.
3. Deploy with an embedded binary commit and resolved config revision.
4. Run bounded private canaries per runtime/model and capability cell.
5. Cross-check journal/receipt, API/transport, and browser projections.
6. Repair failed cells in additional small PRs; never edit the verdict to pass.
7. Repeat until `unresolved_required_cells = 0` and composite live health agrees.
8. Remove obsolete writers/readers and compatibility paths only after every
   producer and consumer has moved to the current SSOT.

CI completion, review completion, merge, deployment, live canary, and campaign
completion are separate states and must be reported separately.
