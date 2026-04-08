---- MODULE KeeperOASAdvanced ----
\* Formal specification of the OAS Bridge timeout/error boundary.
\* Models Eio structured concurrency, OAS-local context rollback, and the
\* critical distinction between clean fallback and committed external tool side
\* effects that require explicit reconcile.

EXTENDS Naturals, Sequences

CONSTANTS MaxTurns

VARIABLES
    sys_stop_requested,  \* Boolean: Global stop signal from the Supervisor
    fiber_state,         \* {"Active", "Cancelling", "Terminated"}
    cascade_turn,        \* 0..MaxTurns: Current depth of the proactive cascade
    oas_api_state,       \* {"Idle", "Fetching", "Success", "Error"}
    keeper_decision,     \* {"Unknown", "ExecuteSelf", "AutonomyFallback", "Delegate", "NeedsReconcile"}
    context_polluted,    \* Boolean: Tracks if intermediate OAS context leaked upon failure
    external_side_effect_committed, \* Boolean: A mutating tool already committed outside OAS context
    reconcile_required   \* Boolean: Human/explicit reconcile is required before claiming clean recovery

vars == <<sys_stop_requested, fiber_state, cascade_turn, oas_api_state,
          keeper_decision, context_polluted,
          external_side_effect_committed, reconcile_required>>

Init ==
    /\ sys_stop_requested = FALSE
    /\ fiber_state = "Active"
    /\ cascade_turn = 0
    /\ oas_api_state = "Idle"
    /\ keeper_decision = "Unknown"
    /\ context_polluted = FALSE
    /\ external_side_effect_committed = FALSE
    /\ reconcile_required = FALSE

\* ── Events ────────────────────────────────────────────────

\* 1. Supervisor requests a stop at any time.
GlobalStopPreempts ==
    /\ sys_stop_requested = FALSE
    /\ sys_stop_requested' = TRUE
    \* If the fiber is active, the Eio switch immediately cancels it.
    /\ IF fiber_state = "Active" THEN fiber_state' = "Cancelling" ELSE fiber_state' = fiber_state
    /\ UNCHANGED <<cascade_turn, oas_api_state, keeper_decision, context_polluted,
                   external_side_effect_committed, reconcile_required>>

\* 2. Eio Timeout (can only happen if Active and Fetching)
EioTimeoutTriggered ==
    /\ fiber_state = "Active"
    /\ oas_api_state = "Fetching"
    /\ fiber_state' = "Cancelling"
    /\ UNCHANGED <<sys_stop_requested, cascade_turn, oas_api_state, keeper_decision,
                   context_polluted, external_side_effect_committed, reconcile_required>>

\* 3. Start fetching from OAS API
StartFetching ==
    /\ fiber_state = "Active"
    /\ oas_api_state \in {"Idle", "Success"}
    /\ cascade_turn < MaxTurns
    /\ oas_api_state' = "Fetching"
    /\ UNCHANGED <<sys_stop_requested, fiber_state, cascade_turn, keeper_decision,
                   context_polluted, external_side_effect_committed, reconcile_required>>

\* 3b. A mutating tool call commits outside the OAS-local context.
ToolSideEffectCommitted ==
    /\ fiber_state = "Active"
    /\ oas_api_state = "Fetching"
    /\ external_side_effect_committed = FALSE
    /\ external_side_effect_committed' = TRUE
    /\ UNCHANGED <<sys_stop_requested, fiber_state, cascade_turn, oas_api_state,
                   keeper_decision, context_polluted, reconcile_required>>

\* 4. OAS API Completes successfully
OASApiCompletes ==
    /\ fiber_state = "Active"
    /\ oas_api_state = "Fetching"
    /\ oas_api_state' = "Success"
    /\ cascade_turn' = cascade_turn + 1
    /\ context_polluted' = TRUE \* Context is dirty (polluted) until cascade completes entirely or rolls back
    /\ UNCHANGED <<sys_stop_requested, fiber_state, keeper_decision,
                   external_side_effect_committed, reconcile_required>>

\* 5. OAS API Fails (Network Error, etc.)
OASApiError ==
    /\ fiber_state = "Active"
    /\ oas_api_state = "Fetching"
    /\ oas_api_state' = "Error"
    /\ UNCHANGED <<sys_stop_requested, fiber_state, cascade_turn, keeper_decision,
                   context_polluted, external_side_effect_committed, reconcile_required>>

\* 6. Bridge Handles OAS Error
HandleError ==
    /\ fiber_state = "Active"
    /\ oas_api_state = "Error"
    /\ external_side_effect_committed = FALSE
    /\ fiber_state' = "Terminated"
    /\ oas_api_state' = "Idle"
    /\ keeper_decision' = "AutonomyFallback"
    /\ context_polluted' = FALSE \* Rollback context to clean state
    /\ reconcile_required' = FALSE
    /\ UNCHANGED <<sys_stop_requested, cascade_turn, external_side_effect_committed>>

\* 6b. Error after a committed external mutation cannot claim clean fallback.
HandleErrorAfterCommittedSideEffect ==
    /\ fiber_state = "Active"
    /\ oas_api_state = "Error"
    /\ external_side_effect_committed = TRUE
    /\ fiber_state' = "Terminated"
    /\ oas_api_state' = "Idle"
    /\ keeper_decision' = "NeedsReconcile"
    /\ context_polluted' = FALSE
    /\ reconcile_required' = TRUE
    /\ UNCHANGED <<sys_stop_requested, cascade_turn, external_side_effect_committed>>

\* 7. Cascade Finishes successfully
FinishCascade ==
    /\ fiber_state = "Active"
    /\ cascade_turn = MaxTurns
    /\ oas_api_state \in {"Success", "Idle"}
    /\ fiber_state' = "Terminated"
    /\ oas_api_state' = "Idle"
    /\ keeper_decision' = "Delegate"
    /\ context_polluted' = FALSE \* Commit context (no longer polluted)
    /\ reconcile_required' = FALSE
    /\ UNCHANGED <<sys_stop_requested, cascade_turn, external_side_effect_committed>>

\* 8. Fiber Handles Cancellation (Interrupts Fetching or Idle/Success states safely)
FiberHandlesCancellation ==
    /\ fiber_state = "Cancelling"
    /\ external_side_effect_committed = FALSE
    /\ fiber_state' = "Terminated"
    /\ oas_api_state' = "Idle" \* Eio interrupts the fetch automatically
    /\ keeper_decision' = "AutonomyFallback"
    /\ context_polluted' = FALSE \* Rollback OAS-local context via try/with
    /\ reconcile_required' = FALSE
    /\ UNCHANGED <<sys_stop_requested, cascade_turn, external_side_effect_committed>>

\* 8b. Cancellation after a committed external mutation leaves context clean
\*     but requires explicit reconcile because the outside world already changed.
CancellationAfterCommittedSideEffect ==
    /\ fiber_state = "Cancelling"
    /\ external_side_effect_committed = TRUE
    /\ fiber_state' = "Terminated"
    /\ oas_api_state' = "Idle"
    /\ keeper_decision' = "NeedsReconcile"
    /\ context_polluted' = FALSE
    /\ reconcile_required' = TRUE
    /\ UNCHANGED <<sys_stop_requested, cascade_turn, external_side_effect_committed>>

\* 9. [BUG MODEL] Catch-all absorbs cancellation — fiber returns Error instead
\*     of propagating Cancelled to the parent switch. This creates a zombie:
\*     the parent believes the child completed, but the cancel signal is lost.
CancelledAbsorbed ==
    /\ fiber_state = "Cancelling"
    /\ fiber_state' = "Terminated"
    /\ oas_api_state' = "Idle"
    \* BUG: keeper_decision becomes a normal result instead of fallback
    /\ keeper_decision' = "ExecuteSelf"
    /\ context_polluted' = TRUE  \* Context NOT rolled back — pollution persists
    /\ reconcile_required' = FALSE
    /\ UNCHANGED <<sys_stop_requested, cascade_turn, external_side_effect_committed>>

TerminatedStutter ==
    /\ fiber_state = "Terminated"
    /\ UNCHANGED vars

\* Correct Next: only well-formed transitions (production code).
Next ==
    \/ GlobalStopPreempts
    \/ EioTimeoutTriggered
    \/ StartFetching
    \/ ToolSideEffectCommitted
    \/ OASApiCompletes
    \/ OASApiError
    \/ HandleError
    \/ HandleErrorAfterCommittedSideEffect
    \/ FinishCascade
    \/ FiberHandlesCancellation
    \/ CancellationAfterCommittedSideEffect
    \/ TerminatedStutter

\* Buggy Next: includes CancelledAbsorbed to demonstrate that
\* CancelledNeverAbsorbed catches the violation. Use NextBuggy in cfg
\* to reproduce the bug scenario for regression testing.
NextBuggy ==
    \/ Next
    \/ CancelledAbsorbed

Fairness ==
    \* Weak Fairness for progress operations
    /\ WF_vars(StartFetching)
    /\ WF_vars(ToolSideEffectCommitted)
    /\ WF_vars(OASApiCompletes)
    /\ WF_vars(OASApiError)
    /\ WF_vars(HandleError)
    /\ WF_vars(HandleErrorAfterCommittedSideEffect)
    /\ WF_vars(FinishCascade)
    /\ WF_vars(FiberHandlesCancellation)
    /\ WF_vars(CancellationAfterCommittedSideEffect)

Spec == Init /\ [][Next]_vars /\ Fairness

SpecBuggy == Init /\ [][NextBuggy]_vars /\ Fairness

\* ── Safety Properties ─────────────────────────────────────

\* 1. A terminated fiber cannot leave a zombie OAS fetch running in the background.
NoZombieFibers == ((fiber_state = "Terminated") => ~(oas_api_state = "Fetching"))

\* 2. A clean fallback means OAS-local context rolled back AND no committed
\*    external mutation remains unresolved.
AtomicCascadeFallback ==
    []((fiber_state = "Terminated" /\ keeper_decision = "AutonomyFallback") =>
        /\ context_polluted = FALSE
        /\ external_side_effect_committed = FALSE
        /\ reconcile_required = FALSE)

\* 3. If a mutating tool already committed and the turn does not finish with
\*    Delegate, the system must surface NeedsReconcile instead of pretending the
\*    fallback was clean.
CommittedSideEffectsRequireReconcile ==
    []((fiber_state = "Terminated"
        /\ external_side_effect_committed
        /\ keeper_decision # "Delegate") =>
        /\ keeper_decision = "NeedsReconcile"
        /\ reconcile_required
        /\ context_polluted = FALSE)

\* 4. Cancellation must never be absorbed — a terminated fiber with polluted
\*    context must never hold a normal decision (ExecuteSelf/Delegate).
\*    State predicate (no temporal ops) — usable as INVARIANT.
\*    Violation means a catch-all swallowed Eio.Cancel.Cancelled.
CancelledNeverAbsorbed ==
    (fiber_state = "Terminated" /\ context_polluted = TRUE)
      => (keeper_decision /= "ExecuteSelf"
          /\ keeper_decision /= "Delegate"
          /\ keeper_decision /= "NeedsReconcile")

\* ── Liveness Properties ───────────────────────────────────

\* 5. If a stop is requested before the fiber finishes, it MUST preempt. The
\*    terminal decision may be clean fallback or NeedsReconcile depending on
\*    whether an external mutation already committed, but it cannot Delegate.
StrictStopPreemption ==
    []((sys_stop_requested /\ fiber_state /= "Terminated")
      ~> (fiber_state = "Terminated"
          /\ keeper_decision # "Delegate"))

\* 6. The fiber must always eventually terminate (no deadlocks or infinite hangs).
EventualTermination == <>(fiber_state = "Terminated")

====
