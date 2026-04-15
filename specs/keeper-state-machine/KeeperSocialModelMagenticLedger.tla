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

ProgressDominates ==
    [](has_progress_evidence' => phase' = "advancing")

ReactiveDominatesIdleTimeout ==
    []((~has_progress_evidence' /\ has_reactive_signal') => phase' = "reactive")

StalledStickyWithGoal ==
    []((phase = "stalled"
        /\ ~has_progress_evidence'
        /\ ~has_reactive_signal'
        /\ has_active_goals'
        /\ ~failure_observed')
       => phase' = "stalled")

QuietWhenNoDrivers ==
    []((~has_progress_evidence'
        /\ ~has_reactive_signal'
        /\ ~has_active_goals'
        /\ ~failure_observed')
       => phase' = "quiet")

=============================================================================
