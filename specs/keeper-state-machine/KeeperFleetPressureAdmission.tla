---- MODULE KeeperFleetPressureAdmission ----
\* KeeperFleetPressureAdmission -- proactive FD-budget admission for 24-keeper fleets.
\*
\* This is the formal target for the 2026-05-15 Keeper 24 failure class:
\* do not wait until EMFILE/ENFILE has already poisoned append/read/spawn
\* paths.  A keeper spawn or turn admission must be blocked before the
\* projected FD budget crosses the inherited process nofile limit.
\*
\* OCaml <-> TLA+ mapping (symbol anchors, not line numbers):
\*
\*   spec variable / action      | OCaml surface
\*   ----------------------------+---------------------------------------------
\*   FdSoftLimit                 | keeper_fd_pressure.ml — process_nofile_soft_limit
\*   FdHeadroom                  | keeper_fd_pressure.ml — fd_headroom
\*   FdPerKeeper                 | keeper_fd_pressure.ml — fd_per_active_keeper
\*   ProjectedFdUse              | keeper_fd_pressure.ml — projected_fd_budget
\*   AdmitKeeper                 | keeper_fd_pressure.ml — admit_start
\*   BlockByBudget               | keeper_fd_pressure.ml — admission_decision
\*   breaker                     | keeper_fd_pressure.ml — active / cooldown_until
\*   active_keepers              | keeper_registry.ml — count_running
\*
\* Scope projection:
\*   The runtime can also trip a reactive cooldown after actual FD exhaustion.
\*   This spec models the proactive admission invariant only: while the runtime
\*   is in charge of a fleet admission decision, it must never admit work that
\*   makes [FdHeadroom + active_keepers * FdPerKeeper] exceed [FdSoftLimit].
\*   Host-wide ENFILE from unrelated processes is outside this process-local
\*   model and remains an operational limit/telemetry concern.
\*
\* Bug model:
\*   Clean cfg  : Safety passes.
\*   Buggy cfg  : AdmitKeeperBuggy ignores [WithinBudget(active_keepers + 1)]
\*                and must violate [NoOverBudgetAdmission].

EXTENDS Naturals

CONSTANTS
    FdSoftLimit,
    FdHeadroom,
    FdPerKeeper,
    MaxKeepers,
    MaxSteps

VARIABLES
    active_keepers,
    breaker,
    last_admitted,
    step

vars == <<active_keepers, breaker, last_admitted, step>>

ProjectedFdUse(k) == FdHeadroom + (k * FdPerKeeper)

WithinBudget(k) == ProjectedFdUse(k) <= FdSoftLimit

TypeOK ==
    /\ FdSoftLimit \in Nat \ {0}
    /\ FdHeadroom \in Nat
    /\ FdPerKeeper \in Nat \ {0}
    /\ MaxKeepers \in Nat
    /\ MaxSteps \in Nat
    /\ active_keepers \in 0..MaxKeepers
    /\ breaker \in BOOLEAN
    /\ last_admitted \in BOOLEAN
    /\ step \in 0..MaxSteps

Init ==
    /\ active_keepers = 0
    /\ breaker = FALSE
    /\ last_admitted = FALSE
    /\ step = 0

\* Proactive admission: a new keeper can be admitted only if the projected
\* fleet budget remains within the process nofile budget.
AdmitKeeper ==
    /\ step < MaxSteps
    /\ ~breaker
    /\ active_keepers < MaxKeepers
    /\ WithinBudget(active_keepers + 1)
    /\ active_keepers' = active_keepers + 1
    /\ last_admitted' = TRUE
    /\ step' = step + 1
    /\ UNCHANGED breaker

\* The desired prevention point: once the next keeper would exceed budget, the
\* admission layer blocks before any EMFILE/ENFILE observation is required.
BlockByBudget ==
    /\ step < MaxSteps
    /\ ~breaker
    /\ active_keepers < MaxKeepers
    /\ ~WithinBudget(active_keepers + 1)
    /\ active_keepers' = active_keepers
    /\ last_admitted' = FALSE
    /\ step' = step + 1
    /\ UNCHANGED breaker

\* Reactive pressure can still happen from outside this model, but while the
\* breaker is active no new admission is allowed.
TripBreaker ==
    /\ step < MaxSteps
    /\ ~breaker
    /\ breaker' = TRUE
    /\ last_admitted' = FALSE
    /\ step' = step + 1
    /\ UNCHANGED active_keepers

RecoverBreaker ==
    /\ step < MaxSteps
    /\ breaker
    /\ breaker' = FALSE
    /\ last_admitted' = FALSE
    /\ step' = step + 1
    /\ UNCHANGED active_keepers

StopKeeper ==
    /\ step < MaxSteps
    /\ active_keepers > 0
    /\ active_keepers' = active_keepers - 1
    /\ last_admitted' = FALSE
    /\ step' = step + 1
    /\ UNCHANGED breaker

Done ==
    /\ step = MaxSteps
    /\ UNCHANGED vars

Next ==
    \/ AdmitKeeper
    \/ BlockByBudget
    \/ TripBreaker
    \/ RecoverBreaker
    \/ StopKeeper
    \/ Done

Spec == Init /\ [][Next]_vars

\* Safety invariants.
NoOverBudgetAdmission == WithinBudget(active_keepers)

NoAdmitWhileBreaker == breaker => ~last_admitted

Safety ==
    /\ TypeOK
    /\ NoOverBudgetAdmission
    /\ NoAdmitWhileBreaker

\* Bug model: admission ignores the projected budget and increments anyway.
AdmitKeeperBuggy ==
    /\ step < MaxSteps
    /\ ~breaker
    /\ active_keepers < MaxKeepers
    /\ active_keepers' = active_keepers + 1
    /\ last_admitted' = TRUE
    /\ step' = step + 1
    /\ UNCHANGED breaker

NextBuggy ==
    \/ AdmitKeeperBuggy
    \/ BlockByBudget
    \/ TripBreaker
    \/ RecoverBreaker
    \/ StopKeeper
    \/ Done

SpecBuggy == Init /\ [][NextBuggy]_vars

====
