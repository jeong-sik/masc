---- MODULE KeeperSocialModelMagenticLedger ----
\* Keeper social model (magentic_ledger_v1) — phase/event FSM.
\*
\* Mirrors:
\*   - lib/keeper/social_model/keeper_social_model_magentic_ledger_fsm.ml
\*
\* Purpose:
\*   - Freeze the phase and event sets for the progress-ledger social model.
\*   - Make the "stalled stays stalled until a new delta arrives" rule explicit.
\*   - Verify that progress evidence dominates other signals, reactive signals
\*     dominate idle timeouts, and empty turns settle to Quiet.
\*
\* Known topology drift (issue #8949): this spec routes the failure signal
\* through [ClassifyEvent] (where "failure dominates progress").  The OCaml
\* impl splits this into two call paths instead:
\*
\*   1. Normal path: [classify_event] (no failure parameter)
\*      handles progress / signals / idle / quiet.
\*   2. Failure path: [derive_failure_state] in
\*      [keeper_social_model.ml] (which dispatches to
\*      [Keeper_social_model_registry.derive_failure_state]) constructs
\*      the [Failure_observed] event directly and bypasses
\*      [classify_event].
\*      (Cited by symbol, not line — iter 64 N-2.a; converted in the
\*      iter 85 scattered-singles line-ref sweep, which also picked up
\*      the rename of keeper_social_model_magentic_ledger_v1.ml →
\*      keeper_social_model.ml + keeper_social_model_registry.ml.)
\*
\* Both topologies reach [Stalled] on failure, so end-state behaviour
\* matches.  However, the spec's "failure dominates progress" property is
\* trivially satisfied in OCaml because failure never reaches the
\* dominance branch.  A future change that adds [has_failure] to the
\* OCaml input record without re-checking dominance ordering would
\* re-introduce the question with the OPPOSITE answer (OCaml's
\* progress-first ordering would override failure).
\*
\* See issue #8949 for proposed alignment options
\* (preferred: re-shape spec to mirror OCaml's two-path topology).

EXTENDS TLC

VARIABLES
    phase,
    has_progress_evidence,
    has_reactive_signal,
    has_active_goals,
    idle_long,
    failure_observed

vars == <<phase, has_progress_evidence, has_reactive_signal,
          has_active_goals, idle_long, failure_observed>>

PhaseSet == {"advancing", "reactive", "stalled", "quiet"}
EventSet == {"progress_observed", "signals_pending", "goal_idle_timeout",
             "all_quiet", "failure_observed"}

ClassifyEvent(progress, reactive, goals, idle, failure, current_phase) ==
    IF failure THEN "failure_observed"
    ELSE IF progress THEN "progress_observed"
    ELSE IF reactive THEN "signals_pending"
    ELSE IF goals /\ (idle \/ current_phase = "stalled")
            THEN "goal_idle_timeout"
    ELSE "all_quiet"

NextPhase(current_phase, event) ==
    CASE event = "progress_observed" -> "advancing"
      [] event = "signals_pending"   -> "reactive"
      [] event = "goal_idle_timeout" -> "stalled"
      [] event = "all_quiet"         -> "quiet"
      [] event = "failure_observed"  -> "stalled"
      [] OTHER -> current_phase

Init ==
    /\ phase = "quiet"
    /\ has_progress_evidence = FALSE
    /\ has_reactive_signal = FALSE
    /\ has_active_goals = FALSE
    /\ idle_long = FALSE
    /\ failure_observed = FALSE

Next ==
    \E progress, reactive, goals, idle, failure \in BOOLEAN:
        /\ has_progress_evidence' = progress
        /\ has_reactive_signal' = reactive
        /\ has_active_goals' = goals
        /\ idle_long' = idle
        /\ failure_observed' = failure
        /\ phase' =
            NextPhase(phase,
                ClassifyEvent(progress, reactive, goals, idle, failure, phase))

\* ── Bug Model: Stalled Without Cause ────────────────────────
\* Models a regression where the phase is incorrectly set to "stalled"
\* without an active goal or failure observed.
\* SHOULD violate StalledNeedsGoalOrFailure.

BugStalledWithoutCause ==
    /\ phase' = "stalled"
    /\ has_progress_evidence' = FALSE
    /\ has_reactive_signal' = FALSE
    /\ has_active_goals' = FALSE
    /\ idle_long' = TRUE
    /\ failure_observed' = FALSE

NextBuggy ==
    \/ Next
    \/ BugStalledWithoutCause

SpecBuggy == Init /\ [][NextBuggy]_vars

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ phase \in PhaseSet
    /\ has_progress_evidence \in BOOLEAN
    /\ has_reactive_signal \in BOOLEAN
    /\ has_active_goals \in BOOLEAN
    /\ idle_long \in BOOLEAN
    /\ failure_observed \in BOOLEAN

ClassifyTypeOK ==
    ClassifyEvent(has_progress_evidence, has_reactive_signal, has_active_goals,
                  idle_long, failure_observed, phase) \in EventSet

StalledNeedsGoalOrFailure ==
    phase = "stalled" => has_active_goals \/ failure_observed

ProgressDominatesAction ==
    (has_progress_evidence' /\ ~failure_observed') => phase' = "advancing"

ReactiveDominatesIdleTimeoutAction ==
    (~failure_observed' /\ ~has_progress_evidence' /\ has_reactive_signal')
    => phase' = "reactive"

StalledStickyWithGoalAction ==
    (phase = "stalled"
     /\ ~has_progress_evidence'
     /\ ~has_reactive_signal'
     /\ has_active_goals'
     /\ ~failure_observed')
    => phase' = "stalled"

QuietWhenNoDriversAction ==
    (~has_progress_evidence'
     /\ ~has_reactive_signal'
     /\ ~has_active_goals'
     /\ ~failure_observed')
    => phase' = "quiet"

ProgressDominates ==
    [][ProgressDominatesAction]_vars

ReactiveDominatesIdleTimeout ==
    [][ReactiveDominatesIdleTimeoutAction]_vars

StalledStickyWithGoal ==
    [][StalledStickyWithGoalAction]_vars

QuietWhenNoDrivers ==
    [][QuietWhenNoDriversAction]_vars

(* Wrapper for buggy cfg — must be defined AFTER the invariant it references. *)
StalledNeedsGoalOrFailureMustHold == StalledNeedsGoalOrFailure

=============================================================================
