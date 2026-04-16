# TLA+ Keeper Decision FSM Gap Analysis

> Status: historical audit only.
> The current authoritative decision-turn contract is the combination of `KeeperTurnCycle.tla`, `KeeperDecisionPipeline.tla`, `KeeperCompositeLifecycle.tla`, and `boundary/KeeperContinueGate.tla`.

Date: 2026-04-13
Auditor: Claude Opus 4.6
Scope: Does the existing TLA+ spec portfolio catch Bug #3 (proactive timer freeze)?

## Bug #3 Summary

**Symptom**: After a scope-only reactive turn (pending_scope_messages present, but no mentions/board events), the proactive cooldown timer froze, preventing the second autonomous turn from ever scheduling.

**Root cause**: `keeper_unified_turn.ml` computed `scope_only_reactive = true` when `pending_scope_messages <> [] && pending_mentions = [] && pending_board_events = []`, then passed `~update_proactive_rt:(not scope_only_reactive)` to `update_metrics_from_result`. This skipped updating `proactive_rt.last_ts`, so the cooldown calculation `Time_compat.now() - proactive_rt.last_ts` returned an ever-growing value -- but since `last_ts` was never refreshed, the cooldown gate `since_last_scheduled_autonomous >= effective_cooldown` was stuck evaluating against a stale timestamp. The next autonomous turn never scheduled because the timer appeared to have never elapsed (or, depending on init state, appeared to have elapsed infinitely long ago, with `last_ts` stuck at 0.0 and no update path).

**Fix**: `355c13fa6` changed `~update_proactive_rt:true` unconditionally. The `scope_only_reactive` variable was removed entirely.

## Spec Inventory: What Each Spec Verifies

### KeeperDecisionPipeline.tla

**Domain**: Guard evaluation, Thompson Sampling, Tool Policy restriction feedback loop.

**Variables**: `fsm_phase` (Running/Failing), `tool_count`, `thompson_alpha/beta`, `guard_penalties_this_cycle`, `turn_outcome`.

**Properties verified**:
- S1 ToolSetNeverEmpty: recovery floor guarantees minimum tools
- S2 RecoveryFloorMaintained: tool_count >= RecoveryFloorSize
- S3 PenaltyCapEnforced: at most PenaltyCapPerCycle penalties per cycle
- L1 FailingEventuallyRecovers: Failing ~> Running

**What it models**: The death-spiral prevention mechanism (guard fires -> Thompson penalty -> tool restriction -> recovery). This is about the *quality feedback loop* during execution, not about *turn scheduling*.

**Bug #3 relevance**: None. This spec does not model turn scheduling, proactive timers, cooldowns, or the reactive/autonomous channel distinction. The word "proactive" does not appear.

### KeeperWorkPipeline.tla (+ KeeperWorkPipelineBug.tla)

**Domain**: Autonomous task execution within a single Running-phase coding task.

**Variables**: `pipeline_phase` (Idle -> Preflight -> WorkspaceInit -> Coding -> Testing -> Reviewing -> Submitting -> ...), workspace lifecycle, identity, budget.

**Properties verified**:
- WorkspaceAlwaysBounded: no path traversal
- IdentityConsistent: commits use keeper identity
- NoForcePush: force push never succeeds
- ReviewBeforeSubmit: at least one review before PR
- EventualCompletion: work eventually reaches terminal
- NoOrphanWorkspace: initialized workspaces always cleaned up

**Bug #3 relevance**: None. This spec models what happens *inside* a turn (coding, testing, reviewing, submitting). It does not model how turns are *scheduled* or when the next turn fires. There is no proactive timer, cooldown, or idle gate.

### KeeperTurnCycle.tla

**Domain**: Single turn execution phases (idle -> planning -> executing -> tool_call -> compacting -> done -> idle).

**Variables**: `turn_phase`, `retry_count`, `tool_calls`, `has_side_effect`, `compaction_needed`, `turn_outcome`, `reconcile_required`.

**Properties verified**:
- Safety: TypeOK, ToolCallsBounded, RetryBounded, DoneHasOutcome, IdleIsClear, PartialOutcomeRequiresReconcile
- NoRetryAfterSideEffectStep: no retry after side-effect commit
- Liveness: TurnEventuallyDone, DoneEventuallyIdle, TurnCycleLive

**Bug #3 relevance**: Marginal. This spec models the turn execution lifecycle, but the `TurnTrigger` action (Idle -> Planning) is unconditional -- it does not model *why* or *when* a turn triggers. The proactive timer decision that gates turn triggering is entirely absent. The spec's `turn_phase = "idle"` simply nondeterministically transitions to `"planning"` with no guard.

### KeeperStateMachine.tla

**Domain**: 11-phase keeper lifecycle (Running, Failing, Compacting, Draining, etc.).

**Variables**: 14 boolean conditions + restart_count. Phase is derived.

**Properties verified**:
- Terminal permanence (Dead/Stopped forever)
- Budget monotonicity
- Running requires fiber_alive
- Failing eventually resolves
- Deadlock freedom

**Bug #3 relevance**: Indirect only. This spec models phase transitions but not the turn scheduling decision within Running phase. The `TurnSucceeded`/`TurnFailed` events are modeled, but the *trigger condition* for attempting a turn (proactive timer, idle gate, cooldown) is not.

## Gap Analysis

### Q1: Does any existing spec model the proactive timer?

**No.** None of the four specs contains variables for:
- `proactive_rt.last_ts` (last proactive turn timestamp)
- `cooldown_elapsed` (boolean: enough time since last autonomous turn)
- `idle_gate_elapsed` (boolean: keeper idle long enough)
- `since_last_scheduled_autonomous` (elapsed seconds)
- `effective_cooldown` (computed cooldown with decay)

The proactive scheduling logic from `keeper_world_observation.ml:unified_turn_decision` (lines 741-878) is entirely unspecified in TLA+.

### Q2: Does any spec model `update_proactive_rt` or `scope_only_reactive`?

**No.** The `update_proactive_rt` flag and the `scope_only_reactive` gate are implementation details of `keeper_unified_turn.ml:update_metrics_from_result`. No spec models the post-turn metric update path or the channel-dependent timestamp update logic.

### Q3: Why didn't TLC catch the freeze?

TLC could not catch it because:

1. **The domain is unmodeled.** The proactive timer scheduling decision exists in a gap between specs. KeeperTurnCycle models what happens *during* a turn. KeeperDecisionPipeline models the *quality feedback* loop. Neither models the *scheduling decision* that gates whether a turn starts.

2. **KeeperTurnCycle's TurnTrigger is unconditionally enabled.** In the spec, a keeper in idle phase can always transition to planning. In reality, the transition is gated by `unified_turn_decision` which checks `idle_gate_elapsed && (cooldown_elapsed || backlog_elapsed)`. The spec abstracts away this gate entirely.

3. **No liveness property about autonomous turn frequency exists.** Even if we added the timer variables, we would need a liveness property like "if proactive is enabled and the keeper is idle long enough, an autonomous turn eventually fires." No such property is defined.

### Q4: Is this an abstraction choice or an oversight?

**Primarily an abstraction boundary gap, secondarily an oversight.**

The existing specs were designed around three clear domains:
- **Lifecycle FSM** (KeeperStateMachine): phase transitions from condition booleans
- **Turn execution** (KeeperTurnCycle): what happens within a single turn
- **Decision quality** (KeeperDecisionPipeline): guard/Thompson/tool feedback loop
- **Work pipeline** (KeeperWorkPipeline): autonomous coding task execution

The *scheduling decision* -- "given world observation, should a turn fire?" -- falls between KeeperStateMachine (which knows about Running phase) and KeeperTurnCycle (which starts from idle). This is a genuine architectural gap in the spec portfolio, not a deliberate abstraction. The `unified_turn_decision` function is one of the most critical pieces of deterministic logic (it gates all autonomous behavior) yet has no formal model.

The gap is further evidenced by the fact that `update_proactive_rt` is a *side-effect of turn completion* that feeds back into *turn scheduling* -- a cross-cutting concern that spans KeeperTurnCycle (turn completion) and the unmodeled scheduling decision.

## What's Missing to Catch Bug #3 Class

### Missing Variables

A new spec (or extension of KeeperTurnCycle) would need:

| Variable | Type | Maps to |
|----------|------|---------|
| `proactive_enabled` | BOOLEAN | `meta.proactive.enabled` |
| `proactive_last_ts` | 0..MaxTime | `proactive_rt.last_ts` (discretized) |
| `current_time` | 0..MaxTime | monotonically increasing clock |
| `cooldown_sec` | Nat | `meta.proactive.cooldown_sec` |
| `idle_sec` | 0..MaxTime | `observation.idle_seconds` |
| `idle_gate_sec` | Nat | `meta.proactive.idle_sec` |
| `has_reactive_trigger` | BOOLEAN | `reactive_triggers <> []` |
| `is_scope_only_reactive` | BOOLEAN | scope msgs present, no mentions/board |
| `update_proactive_rt` | BOOLEAN | the flag passed to `update_metrics_from_result` |

### Missing Actions

| Action | Description |
|--------|-------------|
| `ScheduledAutonomousDecision` | Evaluates idle_gate + cooldown, decides Run/Skip |
| `ReactiveDecision` | Reactive triggers present, always Run |
| `TurnCompletesAndUpdateTimer` | On turn completion, conditionally updates proactive_last_ts |
| `TimeTick` | Advances current_time (models clock progression) |

### Missing Properties

**Safety (invariant)**:
- `ProactiveTimerMonotonic`: `proactive_last_ts' >= proactive_last_ts` (timestamp never goes backward)
- `TimerAlwaysUpdatedOnTurn`: After any turn completes (regardless of channel), if `update_proactive_rt` is true, then `proactive_last_ts` is refreshed

**Liveness (temporal)**:
- `ProactiveEventuallyFires`: `(proactive_enabled /\ idle_gate_elapsed /\ cooldown_elapsed) ~> turn_started` -- if conditions are met, a turn eventually fires
- `TimerNeverFrozen`: `[](proactive_enabled => <>(proactive_last_ts updated))` -- the timer is eventually refreshed (prevents indefinite freeze)

### Missing Bug Model

Following the established Bug Model pattern (clean spec passes, buggy spec violates):

```
BugScopeOnlySkipsTimerUpdate ==
    /\ turn_completing
    /\ is_scope_only_reactive
    /\ update_proactive_rt' = FALSE   \* BUG: scope_only skips update
    /\ proactive_last_ts' = proactive_last_ts  \* Timer frozen
    /\ UNCHANGED <<other vars>>
```

The clean model would always set `update_proactive_rt' = TRUE`. The buggy model would gate it on `~is_scope_only_reactive`. The `TimerNeverFrozen` liveness property would be violated in the buggy model because after a scope-only reactive turn, `proactive_last_ts` never advances, and the scheduling decision remains stuck.

## Proposed Spec: KeeperTurnScheduler.tla

A new spec dedicated to the scheduling decision layer:

**Scope**: Models the `unified_turn_decision` function and its interaction with `update_metrics_from_result`'s proactive timer update. Sits between KeeperStateMachine (provides Running phase) and KeeperTurnCycle (consumes the "should run" decision).

**State space estimate**: With MaxTime=10, 2 boolean triggers, cooldown=3, idle_gate=2: roughly 10 x 10 x 2 x 2 x 2 x 2 = ~1600 states. Tractable for TLC.

**Key insight**: Bug #3 is a cross-domain feedback bug (turn completion side-effect -> scheduling decision input). The spec must model *both* the decision and the post-turn update in a single module to capture this coupling.

**Files to create** (future work, not in this audit):
- `specs/keeper-state-machine/KeeperTurnScheduler.tla` - clean model
- `specs/keeper-state-machine/KeeperTurnScheduler.cfg` - clean config
- `specs/keeper-state-machine/KeeperTurnScheduler-buggy.cfg` - buggy config (scope_only freeze)

## Summary

| Spec | Models Proactive Timer? | Models update_proactive_rt? | Could Catch Bug #3? |
|------|------------------------|-----------------------------|---------------------|
| KeeperDecisionPipeline | No | No | No |
| KeeperWorkPipeline | No | No | No |
| KeeperTurnCycle | No | No | No |
| KeeperStateMachine | No | No | No |
| **KeeperTurnScheduler (proposed)** | **Yes** | **Yes** | **Yes** |

The proactive timer scheduling decision is the single most impactful unspecified deterministic logic in the keeper system. It gates all autonomous behavior, yet has no formal model. Bug #3 is a concrete example of a defect class (cross-domain feedback corruption) that the current spec portfolio structurally cannot detect.
