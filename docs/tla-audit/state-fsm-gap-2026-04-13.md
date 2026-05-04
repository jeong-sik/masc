# TLA+ Keeper State FSM Gap Analysis — Bug #1 (manual_reconcile one-way trap)

> Status: historical audit only, not a live keeper contract.
> Current authoritative keeper FSM set is `KeeperStateMachine`, `KeeperCompositeLifecycle`, `KeeperTurnCycle`, `KeeperDecisionPipeline`, `KeeperCascadeLifecycle`, `KeeperCompactionLifecycle`, and `boundary/KeeperContinueGate`.
> `KeeperReconcileLiveness.tla` and `boundary/KeeperRecoveryOrchestration.tla` are retained here as forensic models for the old two-store reconcile bug.

> **Update 2026-05-05** — §5 disposition recheck:
> - **P1 (TurnSucceeded divergence)** — applied: `KeeperStateMachine.tla` line 128-141 leaves `manual_reconcile_required` UNCHANGED in `TurnSucceeded`, matching the OCaml `Turn_succeeded` branch.
> - **P3 (`ManualReconcileClearable` invariant)** — *no longer applicable in its original form*: the `manual_reconcile_required` variable was removed from `KeeperStateMachine.tla` `VARIABLES` block during a later condition-model refactor (TLC parse fails on the audit's literal proposal — "Unknown operator: manual_reconcile_required"). Re-encoding the "no one-way trap" property requires identifying the new representation; deferred until a spec owner confirms the intended condition model.
> - **P4 (`KeeperRecoveryOrchestration.tla`)** — landed under `specs/boundary/KeeperRecoveryOrchestration.tla` (with `.cfg` and a `-buggy.cfg`), so the multi-event recovery sequence is now under TLC.
> - **P2 / P5** unchanged from the original disposition.

Date: 2026-04-13
Auditor: Claude Opus 4.6 (1M context)
PR: #6834 (fix), this document: audit branch `audit/tla-state-gap`

## 1. Bug Summary

**Bug #1**: `maybe_recover_from_failing` in `keeper_keepalive.ml:774-836` cleared the
manual reconcile data record (via `Keeper_manual_reconcile.clear`) but did not dispatch
`Manual_reconcile_cleared` to the FSM. The FSM condition `manual_reconcile_required`
stayed `true`, `derive_phase` returned `Failing` indefinitely, and the keeper could
never take another turn.

**Root cause**: Two independent state stores — the reconcile data record (filesystem JSON)
and the FSM condition (in-memory `conditions.manual_reconcile_required`) — were updated
independently. The data record was cleared, but the FSM event that clears the condition
was never dispatched.

**Fix (PR #6834)**: After `Keeper_manual_reconcile.clear`, dispatch
`Keeper_state_machine.Manual_reconcile_cleared` to the FSM.

---

## 2. Spec Inventory — What Each Spec Checks

### 2.1 KeeperStateMachine.tla (specs/keeper-state-machine/)

The primary 11-state FSM spec. 12 condition variables, 19 event actions.
Models the pure `derive_phase` + `update_conditions` + transition matrix.

**Key properties checked (all pass):**

| ID | Property | Type | Description |
|----|----------|------|-------------|
| S1 | DeadIsForever | Temporal | `Dead` is absorbing |
| S2 | StoppedIsForever | Temporal | `Stopped` is absorbing |
| S3 | BudgetNeverRevives | Temporal | Budget exhaustion is permanent |
| S5 | RestartCountMonotonic | Temporal | restart_count only increases |
| S6 | RunningRequiresFiber | Temporal | `Running` => `fiber_alive` |
| S7 | StoppedRequiresDrain | Temporal | `Stopped` => stop+drain |
| S8 | DeadRequiresNoBudget | Temporal | `Dead` => no budget |
| S9 | RunningClearsManualReconcile | Temporal | `Running` => NOT manual_reconcile_required |
| L1 | FailingResolves | Liveness | `Failing ~> StablePhases` |
| L2 | CrashedRestartsEventually | Liveness | Crashed w/ budget ~> stable |
| L3 | DrainingResolves | Liveness | Draining ~> stable |
| L4 | CompactingResolves | Liveness | Compacting ~> stable |
| L5 | HandoffResolves | Liveness | HandingOff ~> stable |

**Critical observation**: `TurnSucceeded` in the TLA+ spec clears
`manual_reconcile_required` (line 105: `manual_reconcile_required' = FALSE`),
but in the OCaml code `Turn_succeeded` does NOT clear it (line 311-312:
`{ c with turn_healthy = true }`). This is the central divergence.

### 2.2 KeeperOASAdvanced.tla (specs/keeper-state-machine/)

Models the OAS Bridge timeout/error boundary and Eio structured concurrency.
Focus: cascade fetch lifecycle, side-effect containment, cancellation absorption.

**Properties**: NoZombieFibers, AtomicCascadeFallback, CommittedSideEffectsRequireReconcile,
CancelledNeverAbsorbed, StrictStopPreemption, EventualTermination.

**Relevance to Bug #1**: Models `reconcile_required` as a flag set when external
side-effects are committed + error occurs. Does NOT model the FSM condition
`manual_reconcile_required` or the clearing path. The `reconcile_required` variable
here is the OAS-level concept, not the FSM condition.

### 2.3 KeeperPhaseRace.tla (specs/bug-models/)

Models the phase transition race condition between TurnFail and RequestHandoff.
Uses a simplified 5-phase model (running/failing/cooldown/handing_off/idle).

**Properties**: HandoffMeansClean, CooldownAtThreshold, IdleRequiresHandoff.

**Relevance to Bug #1**: None. This models concurrency races, not the
recovery-to-FSM-dispatch path.

### 2.4 KeeperCoreTriad.tla (specs/keeper-state-machine/)

Composes State Machine x Decision Pipeline x Cascade into a unified model.
Verifies cross-cutting cascade routing properties.

**Properties**: NoTerminalCascade, FailingUsesRecovery, CapabilityGateHolds,
SideEffectContainment, PhaseDecisionConsistency.

**Relevance to Bug #1**: Indirectly relevant. `TurnComplete` action (line 268-284)
transitions `Failing -> Running` on successful turn. But this spec uses a
simplified 5-phase model and delegates `FailingResolves` to KeeperStateMachine.tla.
Does not model `manual_reconcile_required` as a distinct condition.

### 2.5 KeepalivePhaseConsistency.tla (specs/bug-models/)

Models the ghost-dispatch bug: keepalive fiber dispatching turns while keeper
is in a non-dispatchable phase. Uses a simplified 6-phase model.

**Properties**: KeepalivePhaseConsistent, InFlightImpliesRunning.

**Relevance to Bug #1**: Minimal. Models the keepalive-dispatch contract but
not the recovery logic within the keepalive loop.

### 2.6 AmbiguousPartialCommit.tla (specs/bug-models/)

Models the turn lifecycle where tool calls commit side-effects before the LLM
response completes. Timeout after committed mutations creates partial commit.

**Properties**: MutationsNeverOrphan (committed mutations + error -> reconcile,
never silently retried).

**Relevance to Bug #1**: Tangential. This models how reconcile_required gets SET
(on partial commit) but not how it gets CLEARED. The clearing path is absent.

### 2.7 KeeperCircuitBreaker.tla (specs/)

Models the circuit breaker for tool failure recovery (class-isolated failure counting).

**Properties**: CountBounded, TripOnlyWithStreak, TotalTripsMonotonic.

**Relevance to Bug #1**: None.

### 2.8 Additional Specs Read

- **KeeperContextLifecycle.tla**: Context isolation, checkpoint consistency, compaction.
  No manual_reconcile modeling.
- **StateProduct.tla**: Orthogonal composition of keeper/turn/validation dimensions.
  No manual_reconcile modeling.
- **KeeperDecisionPipeline.tla** (referenced but not read in full):
  Decision pipeline guard/tool policy. References TurnSucceeded but only in comments.

---

## 3. Answers to the Five Questions

### Q1: Which spec models the heartbeat recovery path (maybe_recover_from_failing)?

**None.** No TLA+ spec models the `maybe_recover_from_failing` function. This function
lives in `keeper_keepalive.ml` and performs a multi-step recovery:
1. Reset turn failures in registry
2. Dispatch `Heartbeat_ok` to FSM
3. Optionally clear reconcile data record
4. (After fix) Dispatch `Manual_reconcile_cleared` to FSM
5. Dispatch `Turn_succeeded` to FSM

The keepalive recovery logic operates at a higher abstraction level than any individual
spec. KeeperStateMachine.tla models the FSM in isolation (events in, conditions out).
KeepalivePhaseConsistency.tla models the dispatch gating. Neither models the multi-event
recovery sequence that the keepalive loop performs.

### Q2: Does AmbiguousPartialCommit.tla model the recovery -> FSM event dispatch path?

**No.** AmbiguousPartialCommit.tla models how a partial commit ENTERS the reconcile state
(`turn_phase -> "reconcile"` when `mutating_committed > 0 && provider_error`). It does not
model how the system EXITS reconcile. The spec's terminal states are `{completed, failed,
reconcile}` — all of them stutter. There is no action that transitions out of `reconcile`.

This is the fundamental gap: the set-side is modeled, the clear-side is not.

### Q3: Is there a liveness property like `manual_reconcile_required ~> ~manual_reconcile_required`?

**No.** The closest property is `FailingResolves` in KeeperStateMachine.tla:

```
FailingResolves == (Phase = "Failing") ~> (Phase \in StablePhases)
```

This checks that `Failing` eventually reaches a stable phase (`Running`, `Paused`, etc.).
It PASSES because the TLA+ `TurnSucceeded` action clears `manual_reconcile_required`
(line 105), which is the spec-OCaml divergence. With the divergent spec, TLC can always
find a path from Failing to Running via TurnSucceeded, so the liveness property holds
trivially.

A direct `manual_reconcile_required ~> ~manual_reconcile_required` property was never
defined. If it had been defined against the CORRECT OCaml semantics (where TurnSucceeded
does NOT clear it), TLC would have required `ManualReconcileCleared` (a dedicated action
that was originally absent from the recovery path) to satisfy it.

### Q4: Does KeeperStateMachine.tla check that every settable condition has a clearing path?

**No.** There is no systematic "every condition that can be set to true has an action
that sets it to false" property. The spec checks structural properties about phases and
specific conditions (budget permanence, restart count monotonicity, etc.), but does not
have a meta-property that verifies condition-wise reachability of clearing.

The closest is `RunningClearsManualReconcile` (S9):
```
RunningClearsManualReconcile == [](Phase = "Running" => ~manual_reconcile_required)
```
This states that `Running` phase is incompatible with `manual_reconcile_required=true`.
It is a safety invariant, not a liveness property. It does NOT check that the system
can always eventually reach a state where `manual_reconcile_required=false`.

### Q5: Why exactly didn't the existing 108 tests catch this?

The 108 unit tests in `test_keeper_state_machine.ml` test the FSM in isolation — they call
`apply_event` with specific conditions and events and check the result. Two tests are
directly relevant:

1. **`test_apply_turn_succeeded_does_not_clear_manual_reconcile` (line 290)**:
   This test CORRECTLY verifies that `Turn_succeeded` does NOT clear
   `manual_reconcile_required`. It passes. The OCaml code is correct.

2. **`test_apply_manual_reconcile_cleared_clears_manual_reconcile` (line 303)**:
   This test CORRECTLY verifies that `Manual_reconcile_cleared` clears it. It passes.

The tests prove that the FSM layer is correct: the right events produce the right
conditions. The bug was not in the FSM — it was in the CALLER that forgot to dispatch
`Manual_reconcile_cleared`. The 108 tests are integration tests for `keeper_state_machine.ml`,
not for `keeper_keepalive.ml`. There were no tests for the multi-step recovery sequence
in `maybe_recover_from_failing` that verify the complete event dispatch chain.

---

## 4. The Specific Modeling Gap

### 4.1 TLA+ Spec Diverges from OCaml

**KeeperStateMachine.tla line 102-109:**
```tla
TurnSucceeded ==
    /\ NotTerminal /\ fiber_alive
    /\ turn_healthy' = TRUE
    /\ manual_reconcile_required' = FALSE    \* <-- DIVERGENCE
    ...
```

**keeper_state_machine.ml line 311-312:**
```ocaml
| Turn_succeeded ->
    { c with turn_healthy = true }           (* manual_reconcile_required NOT cleared *)
```

The TLA+ spec gives `TurnSucceeded` too much power: it clears both `turn_healthy`
and `manual_reconcile_required`. The OCaml code deliberately keeps them separate:
`Turn_succeeded` only clears `turn_healthy`; only `Manual_reconcile_cleared` clears
`manual_reconcile_required`.

### 4.2 Why the gap was invisible

Because the TLA+ `TurnSucceeded` clears `manual_reconcile_required`, the spec's
`FailingResolves` liveness property (`Failing ~> StablePhases`) passes trivially:
TLC finds a path where `TurnSucceeded` fires and the keeper goes to Running.

If the TLA+ spec matched the OCaml (TurnSucceeded does NOT clear
manual_reconcile_required), then the only path out of Failing-with-manual-reconcile
would be `ManualReconcileCleared`. The spec does have this action (line 120-127 in the
TLA+ file), and it has `WF_vars(HeartbeatOk)` fairness. But there is no fairness
assumption on `ManualReconcileCleared` itself. Without WF/SF on
ManualReconcileCleared, TLC cannot prove `FailingResolves` — the liveness check
would fail, signaling that the clearing path is not guaranteed to execute.

This would have been the early warning: "your liveness property only holds if
ManualReconcileCleared eventually fires, but nothing guarantees that."

### 4.3 Missing spec layer: recovery orchestration

No spec models the keepalive recovery orchestration — the multi-event sequence that
`maybe_recover_from_failing` performs. The specs model:

- FSM layer (KeeperStateMachine.tla): individual events -> conditions -> phases
- OAS bridge layer (KeeperOASAdvanced.tla): cascade fetch -> side-effect -> reconcile
- Turn lifecycle (AmbiguousPartialCommit.tla): tool calls -> partial commit -> reconcile
- Keepalive dispatch (KeepalivePhaseConsistency.tla): phase gating on dispatch

None of them model: "given that the data store says reconcile is needed, the keepalive
recovery must dispatch the correct sequence of FSM events to fully clear the condition."

---

## 5. Concrete Proposals for Fixing the Spec

### P1: Fix the TurnSucceeded divergence (HIGH PRIORITY)

Align KeeperStateMachine.tla `TurnSucceeded` with the OCaml code:

```tla
TurnSucceeded ==
    /\ NotTerminal /\ fiber_alive
    /\ turn_healthy' = TRUE
-   /\ manual_reconcile_required' = FALSE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, manual_reconcile_required,
                   compaction_active, ...>>
```

This will cause `FailingResolves` to fail unless `ManualReconcileCleared` has a
fairness assumption. Add it:

```tla
Fairness ==
    /\ ...existing...
    /\ WF_vars(ManualReconcileCleared)  \* new: clearing must eventually fire
```

After this fix, TLC verifies that the clearing path is structurally necessary for
liveness. If a future code change removes the dispatch, the liveness check fails.

### P2: Add a ManualReconcileCleared action (if absent in the recovery path model)

The current spec has `ManualReconcileCleared` as an action that can fire nondeterministically.
This is correct for the FSM layer. However, to model the actual recovery path, a new
spec should constrain WHEN it fires.

### P3: Add explicit condition-clearing coverage property

Add a new safety/liveness hybrid property that checks every settable condition has a
clearing path:

```tla
\* Every condition that can become true can eventually become false
\* (except in terminal states)
ManualReconcileClearable ==
    (manual_reconcile_required /\ Phase \notin TerminalPhases)
        ~> (~manual_reconcile_required \/ Phase \in TerminalPhases)
```

This is a direct encoding of "no one-way traps for non-terminal states."

### P4: New spec — KeeperRecoveryOrchestration.tla (MEDIUM PRIORITY)

A dedicated spec for the keepalive recovery path that models:

- Variables: `data_record_state` (pending/cleared/absent), `fsm_manual_reconcile`,
  `fsm_turn_healthy`, `fsm_heartbeat_healthy`, `phase`
- Actions:
  - `ClearDataRecord`: clears the filesystem record
  - `DispatchHeartbeatOk`: dispatches to FSM
  - `DispatchManualReconcileCleared`: dispatches to FSM
  - `DispatchTurnSucceeded`: dispatches to FSM
  - `RecoverySequence`: the composite action (all 3-4 dispatches)
- Safety: `DataRecordCleared => FSMConditionCleared` (no orphaned data-vs-FSM state)
- Bug model: `BugRecoverySequence` omits `DispatchManualReconcileCleared`

This directly captures the two-store consistency requirement that Bug #1 violated.

### P5: Add OCaml-TLA+ correspondence test (LOW PRIORITY, HIGH LEVERAGE)

Add a test that generates all (event, condition_field_changed) pairs from both the
TLA+ spec and the OCaml `update_conditions` function, then asserts they are identical.
This catches any future spec-code divergence mechanically.

---

## 6. Summary

| Gap | Impact | Fix |
|-----|--------|-----|
| `TurnSucceeded` divergence (TLA+ clears manual_reconcile, OCaml does not) | Hid the one-way trap from liveness checking | P1: Align spec with code |
| No `ManualReconcileCleared` fairness assumption | Liveness property held trivially | P1: Add WF_vars |
| No condition-clearing coverage property | No detection of one-way traps | P3: Add ManualReconcileClearable |
| No recovery orchestration spec | Multi-event sequences untested by TLC | P4: New KeeperRecoveryOrchestration.tla |
| 108 unit tests cover FSM in isolation, not callers | Caller bugs invisible to FSM tests | Integration tests for recovery sequences |

The root cause is a spec-code divergence in a single line (`manual_reconcile_required' = FALSE`
in TLA+ vs. absent in OCaml). This made the liveness property pass trivially, hiding the
fact that the only real clearing path (`Manual_reconcile_cleared`) was never dispatched
by the recovery code.
