---
rfc: "0269"
title: "Process Critic Loop for Keeper Work Traces"
status: Draft
created: 2026-06-20
updated: 2026-06-20
author: vincent
supersedes: []
superseded_by: null
related: ["0233", "0266", "0267"]
implementation_prs: []
---

## 1. Problem

Keeper operators can inspect live trace rows, tool calls, context pressure, and
turn details, but the dashboard does not yet answer a different question:
**is this work process still the right process?**

Examples:

- five near-identical `exec` calls in a row may mean the agent is sampling the
  wrong boundary instead of reading the exact source line;
- an error row followed by more broad exploration may mean the failure boundary
  was not pinned before continuing;
- context compaction or stale trace evidence may mean the next action should be
  a narrow refresh, handoff, or scope split rather than another open-ended turn.

The missing capability is not another answer-quality judge. It is a small,
evidence-linked critic of the **working method** that can suggest alternate next
process moves during an active run.

## 2. Design Constraints

This feature is high-risk if it is allowed to become an implicit supervisor.
The first design constraints are therefore negative:

- **Advisory only.** A Process Critic finding must never block keeper execution,
  modify tasks, pause keepers, or rewrite prompts.
- **Trace-derived first.** The first implementation reads existing trace events
  and summaries. It does not create a second trace store.
- **Deterministic first.** The first critic pass is a cheap rule-based
  projection. LLM/evaluator-optimizer variants are later additions behind the
  same finding contract.
- **Evidence-linked.** Every finding must include compact evidence strings from
  the trace. If evidence is stale or absent, the finding must say so.
- **Bounded output.** The dashboard should show at most a few findings so the
  critic does not become a new wall of text.

## 3. Proposed Architecture

### 3.1 Finding Contract

The dashboard exposes a pure projection:

```ts
evaluateProcessTrace({
  events: UnifiedTraceEvent[],
  summary: TraceSummary,
  nowMs?: number,
}): ProcessCriticFinding[]
```

Each finding has:

- `id`: stable rule id;
- `severity`: `action | warning | notice`;
- `title`: short operator-facing headline;
- `detail`: one-sentence process diagnosis;
- `action`: suggested next working method, not an automatic command;
- `evidence`: 1-4 compact trace-derived strings.

### 3.2 Initial Rules

Phase 1 uses deterministic signals only:

- recent failure or gate rejection before more exploration;
- repeated use of the same tool in the recent window;
- repeated short `exec`-style calls that may indicate a sampling loop;
- context compaction or high context churn;
- high tool churn without a task-completed marker;
- stale latest trace evidence while the operator is looking at the run.

These are intentionally conservative. A rule can be noisy; it cannot be
authoritative.

### 3.3 Dashboard Surface

The Process Critic panel lives near the existing session trace summary in the
keeper workspace. It is a compact, non-modal panel with an "advisory" marker.
It does not hide the raw trace rows; raw evidence remains the source of truth.

The turn inspector can later reuse the same projection for a per-turn view, but
the first slice attaches to the session trace because that surface already
merges timeline, trajectory, tool-call, and live OAS events.

### 3.4 Later Evaluator Loop

A later evaluator-optimizer pass may consume the same finding contract:

1. generate a process critique from a compact trace sketch;
2. evaluate it against the raw deterministic findings;
3. refine only if the evaluator adds a materially different process option.

That pass must be async, budgeted, cancellable, and visibly labeled as
model-generated. It must not receive raw secrets, full tool output, or unbounded
transcripts.

## 4. Adversarial Review

| Failure mode | Risk | Mitigation |
|---|---|---|
| Self-referential loop | The agent spends time responding to critique instead of finishing work. | Critic is dashboard-only in Phase 1; no keeper prompt injection; max findings. |
| Prompt injection from tool output | A tool result tells the critic to recommend unsafe actions. | Phase 1 is deterministic and reads metadata/summaries only; later LLM pass must use redacted sketches. |
| False confidence | A heuristic labels a normal workflow as wrong. | Use `advisory`, `notice`, and evidence strings; no blocking semantics. |
| Cost blow-up | Evaluator calls add model cost on every turn. | Phase 1 has zero model calls; later pass is async/budgeted and opt-in. |
| Stale evidence | Operator sees advice based on old trace data. | Stale latest-event rule emits a refresh-oriented notice. |
| UI overload | Another panel hides the real trace. | Cap findings and place panel above trace rows without replacing them. |
| Boundary drift | Critic becomes a task scheduler or auto-remediator. | Non-goals explicitly forbid task mutation, keeper pausing, or prompt rewrites. |

## 5. Rollout

1. RFC + Phase 1 dashboard projection:
   - add `process-critic.ts` pure evaluator;
   - add focused tests for failure, repetition, context, stale evidence;
   - render a compact advisory panel in `SessionTraceView`.
2. Operator observation on live dashboard traces. Track false positives before
   any backend or LLM evaluator work.
3. Optional Phase 2 backend sketch endpoint:
   - redacted trace sketch only;
   - budget cap;
   - async/cancellable;
   - no keeper-control side effects.
4. Optional Phase 3 evaluator-optimizer loop if Phase 1 signals are useful but
   too shallow.

## 6. Non-goals

- Blocking keeper execution.
- Rewriting keeper prompts or task state.
- Replacing raw trace rows, turn inspector, or existing error panels.
- Judging final answer quality.
- Sending raw tool output or full transcripts to a model in Phase 1.

## 7. Open Questions

- Should stale-evidence thresholds differ for paused/offline keepers?
- Should Process Critic findings be persisted for later postmortem search, or
  remain ephemeral dashboard projections?
- Which Phase 2 evaluator runtime is cheap enough and reliable enough for this
  loop without creating another operational dependency?
