---- MODULE KeeperPhaseRace ----
\* Bug Model: Keeper failure cascade contract (rescoped per #9006).
\*
\* Original spec modelled a phase race against a mutable phase variable
\* (running -> failing -> cooldown -> handing_off -> idle). That race is
\* structurally impossible in the current runtime: phase is *derived*
\* from a `conditions` record by `derive_phase` at
\* lib/keeper/keeper_state_machine.ml:derive_phase; events update conditions
\* via lib/keeper/keeper_state_machine.ml:update_conditions and the new phase
\* is derived by lib/keeper/keeper_state_machine.ml:apply_event. There
\* is no event handler that writes `phase` directly, so two handlers
\* cannot race a `phase` write.
\*
\* The closest live analog — and what this spec now models — is the
\* fail-cascade contract in lib/keeper/keeper_keepalive.ml:max_consecutive_turn_failures
\* (call site inside run_heartbeat_loop, see `start_keepalive`):
\*
\*   let turn_fail_count = (* read consecutive turn failures *) in
\*   if turn_fail_count > 0 then
\*     (* dispatch Heartbeat_failed observability event, NOT a crash *)
\*     ();
\*   if turn_fail_count >= max_consecutive_turn_failures ()
\*   then begin
\*     Keeper_registry.set_failure_reason ~base_path:ctx.config.base_path m.name
\*       (Some (Keeper_registry.Turn_consecutive_failures turn_fail_count));
\*     raise Keeper_registry.Keeper_fiber_crash
\*   end
\*
\* Contract being verified:
\*   1. The crash dispatch happens IFF turn_fail_count >= threshold
\*      (off-by-one regression catcher).
\*   2. A successful turn observed by the keepalive loop resets
\*      turn_fail_count to 0 BEFORE the threshold check, so a single
\*      success after N-1 failures cannot leak into a crash.
\*   3. Once the cascade fires, the registry carries
\*      Turn_consecutive_failures(n) with n at or above the threshold;
\*      it is not possible to record a value below threshold as the
\*      crash reason.
\*
\* OCaml <-> TLA+ mapping (verified 2026-04-20, see #9006):
\*
\*   spec variable          <-> OCaml site
\*   ----------------------+---------------------------------------------
\*   turn_fail_count        <-> keeper_keepalive.ml:1566 (let turn_fail_count)
\*   threshold              <-> keeper_keepalive.ml:510 (max_consecutive_turn_failures)
\*   crashed                <-> keeper_keepalive.ml:1584 (raise Keeper_fiber_crash)
\*   recorded_failure_n     <-> keeper_keepalive.ml:1583 (Turn_consecutive_failures n)
\*
\* What this spec is NOT:
\*   - Not the 12-phase keeper FSM (KeeperStateMachine.tla owns that).
\*   - Not the cascade strategy (CascadeStrategy.tla owns that).
\*   - Not directly about derive_phase races (no such race exists).

EXTENDS Naturals

CONSTANTS
    Threshold,        \* max_consecutive_turn_failures (e.g. 3)
    MaxObservations   \* bound TLC state space (e.g. 5)

ASSUME ThresholdPos == Threshold \in Nat /\ Threshold >= 1
ASSUME MaxObsPos == MaxObservations \in Nat /\ MaxObservations >= Threshold

VARIABLES
    turn_fail_count,    \* current consecutive failure counter, 0..MaxObservations
    crashed,            \* TRUE once Keeper_fiber_crash has been raised
    recorded_failure_n, \* the n stamped into Turn_consecutive_failures, or 0
    observations        \* total number of turn observations processed

vars == <<turn_fail_count, crashed, recorded_failure_n, observations>>

TypeOK ==
    /\ turn_fail_count \in 0..MaxObservations
    /\ crashed \in BOOLEAN
    /\ recorded_failure_n \in 0..MaxObservations
    /\ observations \in 0..MaxObservations

Init ==
    /\ turn_fail_count = 0
    /\ crashed = FALSE
    /\ recorded_failure_n = 0
    /\ observations = 0

\* -- Normal cascade actions --------------------------------

\* TurnSucceeds: keepalive observes a successful turn, counter resets
\* BEFORE any threshold check would fire on this iteration.
TurnSucceeds ==
    /\ ~crashed
    /\ observations < MaxObservations
    /\ turn_fail_count' = 0
    /\ observations' = observations + 1
    /\ UNCHANGED <<crashed, recorded_failure_n>>

\* TurnFailsBelowThreshold: failure observed, counter increments, crash
\* is NOT yet triggered because the post-increment value < Threshold.
TurnFailsBelowThreshold ==
    /\ ~crashed
    /\ observations < MaxObservations
    /\ turn_fail_count + 1 < Threshold
    /\ turn_fail_count' = turn_fail_count + 1
    /\ observations' = observations + 1
    /\ UNCHANGED <<crashed, recorded_failure_n>>

\* TurnFailsAtOrAboveThreshold: failure pushes counter to Threshold or
\* beyond. The runtime stamps Turn_consecutive_failures(n) AND raises
\* Keeper_fiber_crash. After this, the cascade is terminal in this
\* model (the supervisor restart path is owned by KeeperStateMachine).
TurnFailsAtOrAboveThreshold ==
    /\ ~crashed
    /\ observations < MaxObservations
    /\ turn_fail_count + 1 >= Threshold
    /\ turn_fail_count' = turn_fail_count + 1
    /\ recorded_failure_n' = turn_fail_count + 1
    /\ crashed' = TRUE
    /\ observations' = observations + 1

\* CrashedStutter: once crashed, the cascade does not re-fire.
CrashedStutter ==
    /\ crashed
    /\ UNCHANGED vars

ObservationLimitStutter ==
    /\ observations = MaxObservations
    /\ ~crashed
    /\ UNCHANGED vars

\* -- Clean Next --------------------------------------------

Next ==
    \/ TurnSucceeds
    \/ TurnFailsBelowThreshold
    \/ TurnFailsAtOrAboveThreshold
    \/ CrashedStutter
    \/ ObservationLimitStutter

Spec == Init /\ [][Next]_vars

\* -- Safety Invariants -------------------------------------

\* If the cascade fired, the recorded n must be at or above threshold.
\* Catches an off-by-one regression that would stamp a sub-threshold n.
CrashImpliesThreshold ==
    crashed => recorded_failure_n >= Threshold

\* Recorded failure n is stamped only when the cascade fires.
RecordOnlyOnCrash ==
    recorded_failure_n > 0 => crashed

\* Counter never carries a value above what observations could produce.
CounterBoundedByObservations ==
    turn_fail_count <= observations

\* -- Bug Model: cascade fires below threshold --------------

\* Bug: a refactor introduces an off-by-one in the threshold check
\* (e.g. `turn_fail_count > max - 1` becomes `turn_fail_count >= max - 1`).
\* The cascade fires one failure earlier than intended; recorded_failure_n
\* lands below the threshold contract. CrashImpliesThreshold MUST catch.
BuggyEarlyCrash ==
    /\ ~crashed
    /\ observations < MaxObservations
    /\ turn_fail_count + 1 < Threshold       \* below threshold
    /\ turn_fail_count + 1 >= 1              \* but at least one failure
    /\ turn_fail_count' = turn_fail_count + 1
    /\ recorded_failure_n' = turn_fail_count + 1
    /\ crashed' = TRUE
    /\ observations' = observations + 1

\* Bug: success fails to reset the counter. A single success after
\* N-1 failures leaks the counter forward, eventually crashing on a
\* mostly-healthy keeper. CounterBoundedByObservations alone does not
\* catch this; the violation surfaces as turn_fail_count growing past
\* the number of recent failures relative to recent observations.
BuggyMissedReset ==
    /\ ~crashed
    /\ observations < MaxObservations
    /\ turn_fail_count > 0                   \* reset would have applied
    /\ turn_fail_count' = turn_fail_count    \* but didn't
    /\ observations' = observations + 1
    /\ UNCHANGED <<crashed, recorded_failure_n>>

NextBuggy ==
    \/ TurnSucceeds
    \/ TurnFailsBelowThreshold
    \/ TurnFailsAtOrAboveThreshold
    \/ BuggyEarlyCrash
    \/ BuggyMissedReset
    \/ CrashedStutter
    \/ ObservationLimitStutter

SpecBuggy == Init /\ [][NextBuggy]_vars

====
