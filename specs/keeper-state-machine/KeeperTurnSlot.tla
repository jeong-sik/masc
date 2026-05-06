---- MODULE KeeperTurnSlot ----
\* KeeperTurnSlot -- #12888 productive-slot lifecycle contract.
\*
\* This is the formal target for the 174s <-> 600s slot leak class:
\* once degraded retry routing begins, the outer turn slot must already be
\* released. A retry may later reacquire a fresh productive slot, but it must
\* not keep the same acquisition across the retry phase.
\*
\* OCaml <-> TLA+ mapping:
\*
\*   spec variable / action     | OCaml surface
\*   ---------------------------+----------------------------------------------
\*   ProductivePhaseBudget      | Env_config_keeper.KeeperRetryBackoff.
\*                              | degraded_retry_slot_phase_budget_sec
\*   productive_elapsed         | keeper_unified_turn.current_turn_phase_elapsed_ms
\*   RetryScheduled             | Degraded_retry_allowed branch
\*   ProductivePhaseExhausted   | Degraded_retry_slot_phase_exhausted branch
\*   release_at_phase           | cascade_rotation_attempt.slot_release_at_phase
\*
\* The current runtime mitigation (#13120) rejects late rotation once the
\* productive phase is exhausted; #13272 exposes the release/phase telemetry.
\* This spec pins the stricter #12888 target invariant so future two-tier
\* admission work has a model-level acceptance check.

EXTENDS Naturals

CONSTANTS
    ProductivePhaseBudget,
    MaxRetryTicks,
    MaxSteps

VARIABLES
    phase,
    slot_held,
    slot_held_elapsed,
    productive_elapsed,
    retry_elapsed,
    release_at_phase,
    step

vars ==
    << phase, slot_held, slot_held_elapsed, productive_elapsed,
       retry_elapsed, release_at_phase, step >>

PhaseSet == {"idle", "productive", "retry", "done", "failed"}
ReleasePhaseSet ==
    {"none", "retry_scheduled", "productive_phase_exhausted", "finish"}

TypeOK ==
    /\ ProductivePhaseBudget \in Nat \ {0}
    /\ MaxRetryTicks \in Nat
    /\ MaxSteps \in Nat
    /\ phase \in PhaseSet
    /\ slot_held \in BOOLEAN
    /\ slot_held_elapsed \in 0..ProductivePhaseBudget
    /\ productive_elapsed \in 0..ProductivePhaseBudget
    /\ retry_elapsed \in 0..MaxRetryTicks
    /\ release_at_phase \in ReleasePhaseSet
    /\ step \in 0..MaxSteps

Init ==
    /\ phase = "idle"
    /\ slot_held = FALSE
    /\ slot_held_elapsed = 0
    /\ productive_elapsed = 0
    /\ retry_elapsed = 0
    /\ release_at_phase = "none"
    /\ step = 0

AcquireProductive ==
    /\ step < MaxSteps
    /\ phase = "idle"
    /\ ~slot_held
    /\ phase' = "productive"
    /\ slot_held' = TRUE
    /\ slot_held_elapsed' = 0
    /\ productive_elapsed' = 0
    /\ retry_elapsed' = 0
    /\ release_at_phase' = "none"
    /\ step' = step + 1

ProductiveTick ==
    /\ step < MaxSteps
    /\ phase = "productive"
    /\ slot_held
    /\ productive_elapsed < ProductivePhaseBudget
    /\ slot_held_elapsed < ProductivePhaseBudget
    /\ productive_elapsed' = productive_elapsed + 1
    /\ slot_held_elapsed' = slot_held_elapsed + 1
    /\ step' = step + 1
    /\ UNCHANGED <<phase, slot_held, retry_elapsed, release_at_phase>>

\* First degraded retry decision. The slot is released before the model enters
\* retry phase; a later retry attempt must acquire a fresh productive slot.
RetryScheduled ==
    /\ step < MaxSteps
    /\ phase = "productive"
    /\ slot_held
    /\ productive_elapsed < ProductivePhaseBudget
    /\ phase' = "retry"
    /\ slot_held' = FALSE
    /\ release_at_phase' = "retry_scheduled"
    /\ retry_elapsed' = 0
    /\ step' = step + 1
    /\ UNCHANGED <<slot_held_elapsed, productive_elapsed>>

\* Stop-gap behavior from #13120: if the productive phase is already exhausted,
\* end the cycle so the outer slot is released instead of rotating in place.
ProductivePhaseExhausted ==
    /\ step < MaxSteps
    /\ phase = "productive"
    /\ slot_held
    /\ productive_elapsed >= ProductivePhaseBudget
    /\ phase' = "failed"
    /\ slot_held' = FALSE
    /\ release_at_phase' = "productive_phase_exhausted"
    /\ step' = step + 1
    /\ UNCHANGED <<slot_held_elapsed, productive_elapsed, retry_elapsed>>

FinishProductive ==
    /\ step < MaxSteps
    /\ phase = "productive"
    /\ slot_held
    /\ phase' = "done"
    /\ slot_held' = FALSE
    /\ release_at_phase' = "finish"
    /\ step' = step + 1
    /\ UNCHANGED <<slot_held_elapsed, productive_elapsed, retry_elapsed>>

RetryTick ==
    /\ step < MaxSteps
    /\ phase = "retry"
    /\ ~slot_held
    /\ retry_elapsed < MaxRetryTicks
    /\ retry_elapsed' = retry_elapsed + 1
    /\ step' = step + 1
    /\ UNCHANGED <<phase, slot_held, slot_held_elapsed,
                  productive_elapsed, release_at_phase>>

RetryReacquireProductive ==
    /\ step < MaxSteps
    /\ phase = "retry"
    /\ ~slot_held
    /\ phase' = "productive"
    /\ slot_held' = TRUE
    /\ slot_held_elapsed' = 0
    /\ productive_elapsed' = 0
    /\ release_at_phase' = "none"
    /\ step' = step + 1
    /\ UNCHANGED retry_elapsed

FinishTerminal ==
    /\ step < MaxSteps
    /\ phase \in {"done", "failed"}
    /\ ~slot_held
    /\ phase' = "idle"
    /\ release_at_phase' = "none"
    /\ step' = step + 1
    /\ UNCHANGED <<slot_held, slot_held_elapsed,
                  productive_elapsed, retry_elapsed>>

Next ==
    \/ AcquireProductive
    \/ ProductiveTick
    \/ RetryScheduled
    \/ ProductivePhaseExhausted
    \/ FinishProductive
    \/ RetryTick
    \/ RetryReacquireProductive
    \/ FinishTerminal

Spec == Init /\ [][Next]_vars

\* Safety invariants.
SlotHeldOnlyInProductive ==
    slot_held => phase = "productive"

SlotHeldBoundedByProductiveBudget ==
    slot_held => slot_held_elapsed <= ProductivePhaseBudget

RetryPhaseRequiresReleased ==
    phase = "retry" => ~slot_held

ProductiveExhaustionReleasesSlot ==
    release_at_phase = "productive_phase_exhausted" =>
        /\ phase = "failed"
        /\ ~slot_held

Safety ==
    /\ TypeOK
    /\ SlotHeldOnlyInProductive
    /\ SlotHeldBoundedByProductiveBudget
    /\ RetryPhaseRequiresReleased
    /\ ProductiveExhaustionReleasesSlot

\* Bug model: degraded retry changes the logical phase but forgets to release
\* the slot. TLC must violate RetryPhaseRequiresReleased.
RetryScheduledWithoutRelease ==
    /\ step < MaxSteps
    /\ phase = "productive"
    /\ slot_held
    /\ productive_elapsed < ProductivePhaseBudget
    /\ phase' = "retry"
    /\ slot_held' = TRUE
    /\ release_at_phase' = "retry_scheduled"
    /\ retry_elapsed' = 0
    /\ step' = step + 1
    /\ UNCHANGED <<slot_held_elapsed, productive_elapsed>>

NextBuggy ==
    \/ AcquireProductive
    \/ ProductiveTick
    \/ RetryScheduledWithoutRelease
    \/ ProductivePhaseExhausted
    \/ FinishProductive
    \/ RetryTick
    \/ RetryReacquireProductive
    \/ FinishTerminal

SpecBuggy == Init /\ [][NextBuggy]_vars

====
