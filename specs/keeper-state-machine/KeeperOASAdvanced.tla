---- MODULE KeeperOASAdvanced ----
\* Formal specification of the OAS Bridge timeouts and fallback handling.
\* Rigorously models Eio structured concurrency, cascade rollbacks, and global stop preemptions.

EXTENDS Naturals, Sequences

CONSTANTS MaxTurns

VARIABLES
    sys_stop_requested,  \* Boolean: Global stop signal from the Supervisor
    fiber_state,         \* {"Active", "Cancelling", "Terminated"}
    cascade_turn,        \* 0..MaxTurns: Current depth of the proactive cascade
    oas_api_state,       \* {"Idle", "Fetching", "Success", "Error"}
    keeper_decision,     \* {"Unknown", "ExecuteSelf", "AutonomyFallback", "Delegate"}
    context_polluted     \* Boolean: Tracks if intermediate cascade state leaked upon failure

vars == <<sys_stop_requested, fiber_state, cascade_turn, oas_api_state, keeper_decision, context_polluted>>

Init ==
    /\ sys_stop_requested = FALSE
    /\ fiber_state = "Active"
    /\ cascade_turn = 0
    /\ oas_api_state = "Idle"
    /\ keeper_decision = "Unknown"
    /\ context_polluted = FALSE

\* ── Events ────────────────────────────────────────────────

\* 1. Supervisor requests a stop at any time.
GlobalStopPreempts ==
    /\ sys_stop_requested = FALSE
    /\ sys_stop_requested' = TRUE
    \* If the fiber is active, the Eio switch immediately cancels it.
    /\ IF fiber_state = "Active" THEN fiber_state' = "Cancelling" ELSE fiber_state' = fiber_state
    /\ UNCHANGED <<cascade_turn, oas_api_state, keeper_decision, context_polluted>>

\* 2. Eio Timeout (can only happen if Active and Fetching)
EioTimeoutTriggered ==
    /\ fiber_state = "Active"
    /\ oas_api_state = "Fetching"
    /\ fiber_state' = "Cancelling"
    /\ UNCHANGED <<sys_stop_requested, cascade_turn, oas_api_state, keeper_decision, context_polluted>>

\* 3. Start fetching from OAS API
StartFetching ==
    /\ fiber_state = "Active"
    /\ oas_api_state \in {"Idle", "Success"}
    /\ cascade_turn < MaxTurns
    /\ oas_api_state' = "Fetching"
    /\ UNCHANGED <<sys_stop_requested, fiber_state, cascade_turn, keeper_decision, context_polluted>>

\* 4. OAS API Completes successfully
OASApiCompletes ==
    /\ fiber_state = "Active"
    /\ oas_api_state = "Fetching"
    /\ oas_api_state' = "Success"
    /\ cascade_turn' = cascade_turn + 1
    /\ context_polluted' = TRUE \* Context is dirty (polluted) until cascade completes entirely or rolls back
    /\ UNCHANGED <<sys_stop_requested, fiber_state, keeper_decision>>

\* 5. OAS API Fails (Network Error, etc.)
OASApiError ==
    /\ fiber_state = "Active"
    /\ oas_api_state = "Fetching"
    /\ oas_api_state' = "Error"
    /\ UNCHANGED <<sys_stop_requested, fiber_state, cascade_turn, keeper_decision, context_polluted>>

\* 6. Bridge Handles OAS Error
HandleError ==
    /\ fiber_state = "Active"
    /\ oas_api_state = "Error"
    /\ fiber_state' = "Terminated"
    /\ oas_api_state' = "Idle"
    /\ keeper_decision' = "AutonomyFallback"
    /\ context_polluted' = FALSE \* Rollback context to clean state
    /\ UNCHANGED <<sys_stop_requested, cascade_turn>>

\* 7. Cascade Finishes successfully
FinishCascade ==
    /\ fiber_state = "Active"
    /\ cascade_turn = MaxTurns
    /\ oas_api_state \in {"Success", "Idle"}
    /\ fiber_state' = "Terminated"
    /\ oas_api_state' = "Idle"
    /\ keeper_decision' = "Delegate"
    /\ context_polluted' = FALSE \* Commit context (no longer polluted)
    /\ UNCHANGED <<sys_stop_requested, cascade_turn>>

\* 8. Fiber Handles Cancellation (Interrupts Fetching or Idle/Success states safely)
FiberHandlesCancellation ==
    /\ fiber_state = "Cancelling"
    /\ fiber_state' = "Terminated"
    /\ oas_api_state' = "Idle" \* Eio interrupts the fetch automatically
    /\ keeper_decision' = "AutonomyFallback"
    /\ context_polluted' = FALSE \* Rollback context via Switch.on_release or try/with
    /\ UNCHANGED <<sys_stop_requested, cascade_turn>>

TerminatedStutter ==
    /\ fiber_state = "Terminated"
    /\ UNCHANGED vars

Next ==
    \/ GlobalStopPreempts
    \/ EioTimeoutTriggered
    \/ StartFetching
    \/ OASApiCompletes
    \/ OASApiError
    \/ HandleError
    \/ FinishCascade
    \/ FiberHandlesCancellation
    \/ TerminatedStutter

Fairness ==
    \* Weak Fairness for progress operations
    /\ WF_vars(StartFetching)
    /\ WF_vars(OASApiCompletes)
    /\ WF_vars(OASApiError)
    /\ WF_vars(HandleError)
    /\ WF_vars(FinishCascade)
    /\ WF_vars(FiberHandlesCancellation)

Spec == Init /\ [][Next]_vars /\ Fairness

\* ── Safety Properties ─────────────────────────────────────

\* 1. A terminated fiber cannot leave a zombie OAS fetch running in the background.
NoZombieFibers == ((fiber_state = "Terminated") => ~(oas_api_state = "Fetching"))

\* 2. If a cascade falls back (due to error or cancel), the context must be rolled back cleanly.
AtomicCascadeFallback == []( (fiber_state = "Terminated" /\ keeper_decision = "AutonomyFallback") => (context_polluted = FALSE) )

\* ── Liveness Properties ───────────────────────────────────

\* 3. If a stop is requested before the fiber finishes, it MUST preempt and fall back. It cannot stubbornly Delegate.
StrictStopPreemption == []( (sys_stop_requested /\ fiber_state /= "Terminated") ~> (fiber_state = "Terminated" /\ keeper_decision = "AutonomyFallback") )

\* 4. The fiber must always eventually terminate (no deadlocks or infinite hangs).
EventualTermination == <>(fiber_state = "Terminated")

====
