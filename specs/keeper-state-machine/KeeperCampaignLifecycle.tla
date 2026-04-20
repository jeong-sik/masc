---- MODULE KeeperCampaignLifecycle ----
\* Keeper campaign sub-FSM — pure mission lifecycle for the keeper campaign harness.
\*
\* Mirrors: lib/keeper/keeper_campaign_fsm.ml
\* Goal: prove that campaign verdicts come from a separate mission FSM, not from
\* runtime keeper lifecycle phases.
\*
\* OCaml ↔ TLA+ mapping (see #8642 family):
\*
\*   spec phase string     | OCaml campaign phase variant                          | line
\*   ----------------------+-------------------------------------------------------+-----
\*   "bootstrapping"       | Bootstrapping                                         | lib/keeper/keeper_campaign_fsm.ml:8
\*   "claiming_task"       | Claiming_task                                         | (same module, around line 9)
\*   "task_bound"          | Task_bound                                            | lib/keeper/keeper_campaign_fsm.ml:10
\*   (round-trip via)      | phase_to_string / phase_of_string                     | lib/keeper/keeper_campaign_fsm.ml:71-93
\*
\*   spec variable        | OCaml snapshot field                                   | source
\*   ---------------------+--------------------------------------------------------+--------
\*   taskBound (boolean)  | snapshot.task_id <> None                               | derivable from snapshot.task_id
\*   compactionCount      | snapshot.compaction_count                              | snapshot record
\*   handoffCount         | snapshot.handoff_count                                 | snapshot record
\*   continuityGoal/Task  | snapshot.continuity_*                                  | snapshot record
\*
\* Verdict mapping ↔ OCaml: spec verdicts come from
\* lib/keeper/keeper_campaign_fsm.ml:99 (`verdict_of_phase`) — confirms
\* the spec's design goal that verdicts derive ONLY from the campaign FSM
\* phase, never from the runtime keeper lifecycle phase (which lives in
\* lib/keeper/keeper_state_machine.ml — orthogonal axis).
\*
\* Event mapping ↔ OCaml: spec actions correspond to
\* lib/keeper/keeper_campaign_fsm.ml:33 (`type event`) — Task_bound_observed,
\* etc. apply via `apply_event` at line 287.
\*
\* Scope: spec models the pure mission FSM. The runtime keeper lifecycle
\* (Offline / Running / Crashed / etc.) is intentionally OUT OF SCOPE
\* and lives in sibling specs (KeeperStateMachine, KeeperContextLifecycle).
\* Adding a new keeper lifecycle phase does NOT require updating this
\* spec; adding a new campaign phase DOES.
\*
\* Known modelling gap (issue #8946): [ContinuityObserved] models only the
\* SUCCESS outcome.  The OCaml impl (apply_event at
\* lib/keeper/keeper_campaign_fsm.ml:336-368) ALSO transitions to
\* [Escalated] when goal_matches / task_matches / lifecycle_evidence /
\* target_reached fail, with a textual reason.  TLC therefore cannot
\* reach Escalated via the Continuity_observed path; only via
\* [ErrorObserved].  Any safety/liveness property about the Escalated
\* outcome from this entry point is currently unverified by the model.
\* See issue #8946 for the proposed [ContinuityObservedInsufficientEvidence]
\* sibling action and reason invariant.

EXTENDS Naturals

CONSTANTS MaxPressureObservations

VARIABLES
    phase,
    taskBound,
    searchStarted,
    targetReached,
    pressureStarted,
    compactionCount,
    handoffCount,
    continuityGoalMatches,
    continuityTaskMatches

vars ==
    << phase, taskBound, searchStarted, targetReached, pressureStarted,
       compactionCount, handoffCount,
       continuityGoalMatches, continuityTaskMatches >>

Bootstrapping == "bootstrapping"
ClaimingTask == "claiming_task"
TaskBoundPhase == "task_bound"
Searching == "searching"
TargetReached == "target_reached"
PressureTesting == "pressure_testing"
ContinuityVerified == "continuity_verified"
Stalled == "stalled"
Escalated == "escalated"

Terminal == {ContinuityVerified, Stalled, Escalated}

Init ==
    /\ phase = Bootstrapping
    /\ taskBound = FALSE
    /\ searchStarted = FALSE
    /\ targetReached = FALSE
    /\ pressureStarted = FALSE
    /\ compactionCount = 0
    /\ handoffCount = 0
    /\ continuityGoalMatches = FALSE
    /\ continuityTaskMatches = FALSE

BootstrapOk ==
    /\ phase = Bootstrapping
    /\ phase' = ClaimingTask
    /\ UNCHANGED << taskBound, searchStarted, targetReached, pressureStarted,
                    compactionCount, handoffCount,
                    continuityGoalMatches, continuityTaskMatches >>

TaskBoundObserved ==
    /\ phase = ClaimingTask
    /\ phase' = TaskBoundPhase
    /\ taskBound' = TRUE
    /\ UNCHANGED << searchStarted, targetReached, pressureStarted,
                    compactionCount, handoffCount,
                    continuityGoalMatches, continuityTaskMatches >>

AutoresearchStarted ==
    /\ phase = TaskBoundPhase
    /\ phase' = Searching
    /\ searchStarted' = TRUE
    /\ UNCHANGED << taskBound, targetReached, pressureStarted,
                    compactionCount, handoffCount,
                    continuityGoalMatches, continuityTaskMatches >>

TargetReachedObserved ==
    /\ phase = Searching
    /\ phase' = TargetReached
    /\ targetReached' = TRUE
    /\ UNCHANGED << taskBound, searchStarted, pressureStarted,
                    compactionCount, handoffCount,
                    continuityGoalMatches, continuityTaskMatches >>

PressureStartedObserved ==
    /\ phase = TargetReached
    /\ phase' = PressureTesting
    /\ pressureStarted' = TRUE
    /\ UNCHANGED << taskBound, searchStarted, targetReached,
                    compactionCount, handoffCount,
                    continuityGoalMatches, continuityTaskMatches >>

CompactionObserved ==
    /\ phase = PressureTesting
    /\ compactionCount + handoffCount < MaxPressureObservations
    /\ phase' = phase
    /\ compactionCount' = compactionCount + 1
    /\ UNCHANGED << taskBound, searchStarted, targetReached, pressureStarted,
                    handoffCount, continuityGoalMatches, continuityTaskMatches >>

HandoffObserved ==
    /\ phase = PressureTesting
    /\ compactionCount + handoffCount < MaxPressureObservations
    /\ phase' = phase
    /\ handoffCount' = handoffCount + 1
    /\ UNCHANGED << taskBound, searchStarted, targetReached, pressureStarted,
                    compactionCount, continuityGoalMatches, continuityTaskMatches >>

ContinuityObserved ==
    /\ phase = PressureTesting
    /\ targetReached
    /\ compactionCount + handoffCount > 0
    /\ phase' = ContinuityVerified
    /\ continuityGoalMatches' = TRUE
    /\ continuityTaskMatches' = TRUE
    /\ UNCHANGED << taskBound, searchStarted, targetReached, pressureStarted,
                    compactionCount, handoffCount >>

WindowExhausted ==
    /\ phase \in {ClaimingTask, TaskBoundPhase, Searching, PressureTesting}
    /\ phase' = Stalled
    /\ UNCHANGED << taskBound, searchStarted, targetReached, pressureStarted,
                    compactionCount, handoffCount,
                    continuityGoalMatches, continuityTaskMatches >>

ErrorObserved ==
    /\ phase \notin Terminal
    /\ phase' = Escalated
    /\ UNCHANGED << taskBound, searchStarted, targetReached, pressureStarted,
                    compactionCount, handoffCount,
                    continuityGoalMatches, continuityTaskMatches >>

Stutter ==
    /\ phase \in Terminal
    /\ UNCHANGED vars

Next ==
    \/ BootstrapOk
    \/ TaskBoundObserved
    \/ AutoresearchStarted
    \/ TargetReachedObserved
    \/ PressureStartedObserved
    \/ CompactionObserved
    \/ HandoffObserved
    \/ ContinuityObserved
    \/ WindowExhausted
    \/ ErrorObserved
    \/ Stutter

BootstrapProgress ==
    \/ BootstrapOk
    \/ TaskBoundObserved
    \/ AutoresearchStarted
    \/ TargetReachedObserved
    \/ PressureStartedObserved

SearchResolution ==
    \/ TargetReachedObserved
    \/ WindowExhausted
    \/ ErrorObserved

PressureResolution ==
    \/ ContinuityObserved
    \/ WindowExhausted
    \/ ErrorObserved

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(BootstrapProgress)
    /\ WF_vars(SearchResolution)
    /\ WF_vars(PressureResolution)

\* Buggy model: continuity can be marked complete without lifecycle evidence
\* or preserved goal/task lineage.
ContinuityObservedBuggy ==
    /\ phase = PressureTesting
    /\ phase' = ContinuityVerified
    /\ continuityGoalMatches' = FALSE
    /\ continuityTaskMatches' = FALSE
    /\ UNCHANGED << taskBound, searchStarted, targetReached, pressureStarted,
                    compactionCount, handoffCount >>

NextBuggy ==
    \/ BootstrapOk
    \/ TaskBoundObserved
    \/ AutoresearchStarted
    \/ TargetReachedObserved
    \/ PressureStartedObserved
    \/ CompactionObserved
    \/ HandoffObserved
    \/ ContinuityObservedBuggy
    \/ WindowExhausted
    \/ ErrorObserved
    \/ Stutter

SpecBuggy ==
    /\ Init
    /\ [][NextBuggy]_vars
    /\ WF_vars(BootstrapProgress)
    /\ WF_vars(SearchResolution)
    /\ WF_vars(PressureResolution)

NoSearchBeforeTaskBound ==
    searchStarted => taskBound

NoPressureBeforeTargetReached ==
    pressureStarted => targetReached

ContinuityRequiresEvidence ==
    phase = ContinuityVerified =>
      /\ targetReached
      /\ compactionCount + handoffCount > 0
      /\ continuityGoalMatches
      /\ continuityTaskMatches

TerminalStatesStable ==
    phase \in Terminal =>
      (phase = ContinuityVerified \/ phase = Stalled \/ phase = Escalated)

SearchingEventuallyTerminates ==
    [] (phase = Searching => <> (phase \in {TargetReached, Stalled, Escalated}))

PressureEventuallyResolves ==
    [] (phase = PressureTesting => <> (phase \in Terminal))

====
