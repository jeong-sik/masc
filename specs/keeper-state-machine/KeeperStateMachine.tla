---- MODULE KeeperStateMachine ----
\* Keeper lifecycle authority projection.
\*
\* This model contains only typed intent and durable lifecycle state.
\* Runtime observations may select an observable phase, but only explicit
\* operator intent may pause or stop a Keeper and only an explicit durable
\* tombstone may enter Dead. Failing, Overflowed, Compacting, and HandingOff
\* remain work-capable; they do not grant or deny effects. External effects
\* are authorized independently by the Gate.
\*
\* Mirrors the lifecycle authority subset of
\* lib/keeper_registry/keeper_state_machine.{ml,mli}.

EXTENDS TLC

VARIABLES
    phase,
    fiber_alive,
    operator_paused,
    stop_requested,
    restart_requested,
    dead_tombstone_latched

vars == << phase, fiber_alive, operator_paused, stop_requested,
           restart_requested, dead_tombstone_latched >>

PhaseSet == {
    "Offline",
    "Running",
    "Failing",
    "Overflowed",
    "Compacting",
    "HandingOff",
    "Draining",
    "Paused",
    "Stopped",
    "Crashed",
    "Restarting",
    "Dead"
}

\* These phases remain eligible to continue lane-local work. The set has no
\* effect-authorization meaning; the Gate owns that boundary.
WorkCapable == {
    "Running", "Failing", "Overflowed", "Compacting", "HandingOff"
}

Terminal == {"Stopped", "Dead"}

TypeOK ==
    /\ phase \in PhaseSet
    /\ fiber_alive \in BOOLEAN
    /\ operator_paused \in BOOLEAN
    /\ stop_requested \in BOOLEAN
    /\ restart_requested \in BOOLEAN
    /\ dead_tombstone_latched \in BOOLEAN

Init ==
    /\ phase \in {"Offline", "Running"}
    /\ fiber_alive = (phase = "Running")
    /\ operator_paused = FALSE
    /\ stop_requested = FALSE
    /\ restart_requested = FALSE
    /\ dead_tombstone_latched = FALSE

FiberStarted ==
    /\ phase \in {"Offline", "Restarting"}
    /\ ~fiber_alive
    /\ fiber_alive' = TRUE
    /\ restart_requested' = FALSE
    /\ phase' = IF stop_requested
                THEN "Draining"
                ELSE IF operator_paused THEN "Paused" ELSE "Running"
    /\ UNCHANGED << stop_requested, operator_paused,
                    dead_tombstone_latched >>

FiberTerminated ==
    /\ phase \notin Terminal
    /\ fiber_alive
    /\ phase' = "Crashed"
    /\ fiber_alive' = FALSE
    /\ UNCHANGED << operator_paused, stop_requested, restart_requested,
                    dead_tombstone_latched >>

\* A typed supervisor request is intent, not elapsed backoff or a retry floor.
SupervisorRestartRequested ==
    /\ phase = "Crashed"
    /\ ~fiber_alive
    /\ restart_requested' = TRUE
    /\ phase' = "Restarting"
    /\ UNCHANGED << fiber_alive, operator_paused, stop_requested,
                    dead_tombstone_latched >>

OperatorPause ==
    /\ phase \in WorkCapable
    /\ operator_paused' = TRUE
    /\ phase' = "Paused"
    /\ UNCHANGED << fiber_alive, stop_requested, restart_requested,
                    dead_tombstone_latched >>

OperatorResume ==
    /\ phase = "Paused"
    /\ operator_paused
    /\ operator_paused' = FALSE
    /\ phase' = "Running"
    /\ UNCHANGED << fiber_alive, stop_requested, restart_requested,
                    dead_tombstone_latched >>

OperatorStop ==
    /\ phase \notin Terminal
    /\ stop_requested' = TRUE
    /\ phase' = "Draining"
    /\ UNCHANGED << fiber_alive, operator_paused, restart_requested,
                    dead_tombstone_latched >>

DrainComplete ==
    /\ phase = "Draining"
    /\ stop_requested
    /\ phase' = "Stopped"
    /\ UNCHANGED << fiber_alive, operator_paused, stop_requested,
                    restart_requested, dead_tombstone_latched >>

\* Failure is an observation. It does not pause, stop, or kill the Keeper.
FailureObserved ==
    /\ phase \in WorkCapable
    /\ phase' = "Failing"
    /\ UNCHANGED << fiber_alive, operator_paused, stop_requested,
                    restart_requested, dead_tombstone_latched >>

FailureCleared ==
    /\ phase = "Failing"
    /\ phase' = "Running"
    /\ UNCHANGED << fiber_alive, operator_paused, stop_requested,
                    restart_requested, dead_tombstone_latched >>

\* Context overflow is telemetry. It carries no lifecycle authority.
ContextOverflowObserved ==
    /\ phase \notin Terminal
    /\ UNCHANGED vars

\* Compaction and handoff are explicit lifecycle events. Their phases remain
\* work-capable and do not suppress unrelated lane activity.
CompactionStarted ==
    /\ phase \in WorkCapable
    /\ phase' = "Compacting"
    /\ UNCHANGED << fiber_alive, operator_paused, stop_requested,
                    restart_requested, dead_tombstone_latched >>

CompactionFinished ==
    /\ phase = "Compacting"
    /\ phase' = "Running"
    /\ UNCHANGED << fiber_alive, operator_paused, stop_requested,
                    restart_requested, dead_tombstone_latched >>

HandoffStarted ==
    /\ phase \in WorkCapable
    /\ phase' = "HandingOff"
    /\ UNCHANGED << fiber_alive, operator_paused, stop_requested,
                    restart_requested, dead_tombstone_latched >>

HandoffFinished ==
    /\ phase = "HandingOff"
    /\ phase' = "Running"
    /\ UNCHANGED << fiber_alive, operator_paused, stop_requested,
                    restart_requested, dead_tombstone_latched >>

DeadTombstoneRecorded ==
    /\ phase \notin Terminal
    /\ dead_tombstone_latched' = TRUE
    /\ phase' = "Dead"
    /\ fiber_alive' = FALSE
    /\ UNCHANGED << operator_paused, stop_requested, restart_requested >>

TerminalStutter ==
    /\ phase \in Terminal
    /\ UNCHANGED vars

Next ==
    \/ FiberStarted
    \/ FiberTerminated
    \/ SupervisorRestartRequested
    \/ OperatorPause
    \/ OperatorResume
    \/ OperatorStop
    \/ DrainComplete
    \/ FailureObserved
    \/ FailureCleared
    \/ ContextOverflowObserved
    \/ CompactionStarted
    \/ CompactionFinished
    \/ HandoffStarted
    \/ HandoffFinished
    \/ DeadTombstoneRecorded
    \/ TerminalStutter

Spec == Init /\ [][Next]_vars

DeadIsForever == [](phase = "Dead" => [](phase = "Dead"))
StoppedIsForever == [](phase = "Stopped" => [](phase = "Stopped"))
TombstoneNeverClears ==
    [](dead_tombstone_latched => [](dead_tombstone_latched))

DeadRequiresTombstone ==
    phase = "Dead" => dead_tombstone_latched

PausedRequiresOperator ==
    phase = "Paused" => operator_paused

StoppedRequiresOperatorStop ==
    phase = "Stopped" => stop_requested

RestartingRequiresTypedIntent ==
    phase = "Restarting" => restart_requested

\* Bug witness: an observed failure is incorrectly promoted to Stopped without
\* operator intent. This must violate StoppedRequiresOperatorStop.
BuggyFailureStops ==
    /\ phase \in WorkCapable
    /\ ~stop_requested
    /\ phase' = "Stopped"
    /\ UNCHANGED << fiber_alive, operator_paused, stop_requested,
                    restart_requested, dead_tombstone_latched >>

NextBuggy == Next \/ BuggyFailureStops
SpecBuggy == Init /\ [][NextBuggy]_vars

====
