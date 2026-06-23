# RFC-0216: Per-Keeper Decline Memory (orphan-task churn root fix)

- **Status**: Draft
- **Supersedes**: RFC-0034 cooldown approach (unimplemented Draft — see §"Why not RFC-0034's cooldown")
- **Related**: RFC-0123 (briefing as typed contract), RFC-0124 (typed denial boundary), #20075 (stale-claim TTL — orthogonal; see §Composition)

## Problem

Measured (`<MASC_BASE_PATH>/.masc/logs/system_log_2026-06-04.jsonl`): 132 task releases in one day across 11 tasks; `task-575` alone claimed↔released ~60 cycles over 5.5h (00:56→06:35) with zero completion. Each cycle: claim → start → real keeper execution (~30s–8min) → release. A slow livelock that burns keeper turns and LLM execution continuously. It is benign for safety (`workflow_rejection` is circuit-breaker-exempt, no data loss) but drains a measurable fraction of keeper capacity.

The driver is an active, reasoned decline, e.g. the recorded release reason `"Releasing P3 planning task — implementation keeper 不适合 P3 plan. Going for P1 implementable cleanup."` — a keeper claims a task, judges it unsuitable, releases it; the scheduler offers the same task back; repeat.

## Root cause

The decline signal is recorded but write-only — never read at the two decision points:

- `task.cycle_count` (`lib/types/types_core.ml:535`) is incremented on every Release (`lib/workspace/workspace_task_transitions.ml:402`) and WARN-logged at 5/10/20, but `claim_next_r` (`lib/workspace/workspace_task_schedule.ml:314-388`) sorts by priority+age and never reads it.
- `handoff_context.reason` (`types_core.ml:511-520`, the keeper's "unsuitable" rationale) is persisted but never consulted in selection — narrative text, not a typed signal.
- Keeper `world_observation` (`lib/keeper/keeper_world_observation.ml:29-47`) carries only aggregate counts (`unclaimed_task_count`, `claimable_task_count`, ...) — no per-task decline history. `wip_rejections` is a turn-local `ref []` discarded at turn end (`lib/keeper/keeper_tool_task_runtime.ml:526-552`).

Every keeper re-selects a declined task as if it were new: the system has the decline information but does not consult it when deciding what to offer.

## Mechanism (one change)

**Per-keeper decline memory, consumed at selection and surfaced in the briefing. No threshold, no timer.**

1. On a Release that carries an explicit decline, record a typed decline on the task: `{ keeper_id; decline_reason : <closed variant>; declined_at }` appended to a new `task.decline_history`. This replaces the write-only `cycle_count`/narrative-`reason` with a signal that selection consumes.
2. `claim_next_r` excludes, *for a given keeper*, any task that keeper has an unexpired decline for. This is per-keeper, not a global counter.
3. `world_observation` surfaces the keeper's own recent declines so the keeper itself avoids re-claiming.

**Emergent properties — no extra machinery required:**

- **Natural quarantine.** When every running keeper has declined a task, it is absent from all claimable sets. No magic-N threshold, no quarantine state, no escalation module, no human escape hatch.
- **Reactive routing.** A keeper that has *not* declined a task (e.g. a planning-capable keeper, or a future keeper) can still claim it. This captures most of the benefit of task↔keeper capability routing with no capability taxonomy and no string classifier.

## The one design decision: expiry

Per-keeper decline memory must expire; otherwise a keeper that declined a task while transiently busy would never retry a task it could later do. Options:

- (a) time-based TTL — decline expires after a fixed window;
- (b) until the task materially changes (new handoff / priority / files);
- (c) until the keeper's role/context changes.

**Recommendation: (a) time-based TTL**, simplest and observable, value as a named constant + env override. This is the single point requiring human sign-off.

## Composition with #20075 (stale-claim TTL)

#20075 added `stale_claim_timeout_sec` / `Stale_claim_outcome` (`lib/orchestrator.ml`): a claim held too long without progress is force-released. That is orthogonal — a stale-claim auto-release is *not* a suitability judgment. Decline memory must record **only** Release events that carry an explicit decline reason; stale-claim auto-releases and normal completions do not poison decline memory.

## Why not RFC-0034's cooldown (workaround bar)

RFC-0034 is an unimplemented Draft (git history shows only mechanical sweep commits; the cooldown machinery `Task_cooldowns`/`TaskInCooldown` exists nowhere in `lib/`; its "Pure observation: does not block" line describes the *current* observation-only logging, not a deliberate decision to never block). It proposes a `cycle_count`-based cooldown (delay re-offer for COOLDOWN_SEC) plus human escalation at cycle_count≥20.

That is the `cap/cooldown` symptom-suppression signature (CLAUDE.md workaround bar): it delays re-offer and dumps undoable tasks on a human without making the discarded decline signal load-bearing. Per-keeper decline memory instead consumes the existing signal at the point of decision:

- not telemetry-as-fix (the signal gates selection; it is not merely logged),
- not cooldown (no timer or global threshold governs re-offer),
- not N-of-M (per-keeper exclusion, not a count).

The existing oscillation WARN logging (observation) is preserved.

## Deferred (build only on evidence the core is insufficient)

- **Threshold quarantine + escalation routing** (a decline-semantic version of RFC-0034): build only if per-keeper memory does not drain the churn. Building a quarantine state + escalation queue + recovery action + dashboard now would be speculative machinery with no consumer.
- **Task↔keeper capability typing/routing**: the ideal *proactive* match, but it requires a capability taxonomy (string-classifier risk) and per-task assignment effort. Defer; per-keeper memory captures most of the benefit reactively.

## Code touch points

- `lib/types/types_core.ml:511-538` — typed `decline_reason` (closed variant) + `decline_history` field on `task` (default `[]`, backward-compatible).
- `lib/workspace/workspace_task_transitions.ml:~402` — on Release-with-decline, append a typed decline; leave stale-claim/completion releases untouched.
- `lib/workspace/workspace_task_schedule.ml:314-388` — `claim_next_r` per-keeper decline exclusion, with expiry.
- `lib/keeper/keeper_world_observation.ml:29-47` — surface the keeper's own recent declines.

## Verification

Harness-testable, deterministic:

- a keeper that declines task X is not re-offered X within the TTL;
- a keeper that has not declined X can still claim X;
- when all running keepers have declined X, X is absent from every claimable set;
- tasks with no declines behave exactly as today (behavior-preserving).
