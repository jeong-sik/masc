---- MODULE KeeperReconcileLiveness ----
\* Keeper Reconcile Liveness — TLA+ Specification
\*
\* Verifies that manual_reconcile_required is not a one-way trap:
\* once set, the system can always eventually clear it.
\*
\* Background (masc-mcp#6841+):
\*   manual_reconcile_required was set to TRUE by OAS bridge failures
\*   (committed external side effects during cascade errors), but the
\*   heartbeat recovery path only dispatched Turn_succeeded without
\*   dispatching Manual_reconcile_cleared.  Since Turn_succeeded does
\*   NOT clear manual_reconcile_required in the OCaml FSM (only
\*   Manual_reconcile_cleared and Fiber_started do), the flag stayed
\*   TRUE forever, permanently trapping the keeper in Failing.
\*
\* IMPORTANT: The existing KeeperStateMachine.tla has a model-to-code
\* discrepancy: its TurnSucceeded action sets manual_reconcile_required'
\* = FALSE, which masks this bug.  This spec models the OCaml behavior
\* faithfully: TurnSucceeded does NOT clear manual_reconcile_required.
\*
\* Key properties:
\*   L1 ManualReconcileLiveness:   blocked => eventually unblocked
\*   L2 FailingRecoveryLiveness:   Failing => eventually Running (or terminal)
\*   L3 HeartbeatRecoveryAtomic:   recovery dispatches BOTH Turn_succeeded
\*                                 AND Manual_reconcile_cleared
\*
\* Bug model: recovery only dispatches Turn_succeeded (old code).
\* The liveness property MUST be violated in the buggy variant.
\*
\* Mirrors: lib/keeper/keeper_state_machine.ml (update_conditions)
\*          lib/keeper/keeper_keepalive.ml:800-835 (heartbeat recovery)

EXTENDS Naturals

CONSTANTS MaxRestarts

VARIABLES
    fiber_alive,
    heartbeat_healthy,
    turn_healthy,
    manual_reconcile_required,
    compaction_active,
    handoff_active,
    operator_paused,
    stop_requested,
    restart_budget_remaining,
    backoff_elapsed,
    guardrail_triggered,
    drain_complete,
    restart_count

vars == <<fiber_alive, heartbeat_healthy, turn_healthy,
          manual_reconcile_required,
          compaction_active, handoff_active, operator_paused,
          stop_requested, restart_budget_remaining, backoff_elapsed,
          guardrail_triggered, drain_complete, restart_count>>

\* ── Phase Derivation (matching OCaml derive_phase) ──────

DerivePhase ==
    IF stop_requested /\ drain_complete
       /\ ~compaction_active /\ ~handoff_active THEN "Stopped"
    ELSE IF ~fiber_alive /\ ~restart_budget_remaining THEN "Dead"
    ELSE IF ~fiber_alive /\ restart_budget_remaining /\ backoff_elapsed THEN "Restarting"
    ELSE IF ~fiber_alive /\ restart_budget_remaining THEN "Crashed"
    ELSE IF stop_requested THEN "Draining"
    ELSE IF guardrail_triggered THEN "Failing"
    ELSE IF operator_paused THEN "Paused"
    ELSE IF handoff_active THEN "HandingOff"
    ELSE IF compaction_active THEN "Compacting"
    ELSE IF ~heartbeat_healthy \/ ~turn_healthy \/ manual_reconcile_required THEN "Failing"
    ELSE IF fiber_alive THEN "Running"
    ELSE "Offline"

Phase == DerivePhase
TerminalPhases == {"Stopped", "Dead"}
NotTerminal == Phase \notin TerminalPhases
RecoverablePhases == {"Running", "Paused", "Crashed", "Stopped", "Dead", "Offline"}

\* ── Initial State ─────────────────────────────────────────

Init ==
    /\ fiber_alive = TRUE
    /\ heartbeat_healthy = TRUE
    /\ turn_healthy = TRUE
    /\ manual_reconcile_required = FALSE
    /\ compaction_active = FALSE
    /\ handoff_active = FALSE
    /\ operator_paused = FALSE
    /\ stop_requested = FALSE
    /\ restart_budget_remaining = TRUE
    /\ backoff_elapsed = FALSE
    /\ guardrail_triggered = FALSE
    /\ drain_complete = FALSE
    /\ restart_count = 0

\* ── Events (faithful to OCaml update_conditions) ─────────

HeartbeatOk ==
    /\ NotTerminal /\ fiber_alive
    /\ heartbeat_healthy' = TRUE
    /\ UNCHANGED <<fiber_alive, turn_healthy, manual_reconcile_required,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete, restart_count>>

HeartbeatFailed ==
    /\ NotTerminal /\ fiber_alive
    /\ heartbeat_healthy' = FALSE
    /\ UNCHANGED <<fiber_alive, turn_healthy, manual_reconcile_required,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete, restart_count>>

\* CRITICAL DIFFERENCE from KeeperStateMachine.tla:
\* TurnSucceeded does NOT clear manual_reconcile_required.
\* This matches OCaml: { c with turn_healthy = true }
TurnSucceeded ==
    /\ NotTerminal /\ fiber_alive
    /\ turn_healthy' = TRUE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, manual_reconcile_required,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete, restart_count>>

TurnFailed ==
    /\ NotTerminal /\ fiber_alive
    /\ turn_healthy' = FALSE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, manual_reconcile_required,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete, restart_count>>

ManualReconcileRequired ==
    /\ NotTerminal /\ fiber_alive
    /\ manual_reconcile_required' = TRUE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete, restart_count>>

\* Explicit clear of manual_reconcile_required.
\* OCaml: Manual_reconcile_cleared -> { c with manual_reconcile_required = false }
ManualReconcileCleared ==
    /\ NotTerminal /\ fiber_alive
    /\ manual_reconcile_required' = FALSE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete, restart_count>>

\* HeartbeatRecovery: the FIXED code path from keeper_keepalive.ml:800-835.
\* Dispatches Heartbeat_ok + Turn_succeeded + Manual_reconcile_cleared atomically.
\* In the real code these are 3 sequential dispatch_event calls, but since
\* Eio is cooperative and no yield point exists between them, the effect is atomic.
HeartbeatRecovery ==
    /\ NotTerminal /\ fiber_alive
    /\ manual_reconcile_required   \* Only fires when reconcile is blocking
    /\ heartbeat_healthy' = TRUE
    /\ turn_healthy' = TRUE
    /\ manual_reconcile_required' = FALSE
    /\ UNCHANGED <<fiber_alive, compaction_active, handoff_active,
                   operator_paused, stop_requested, restart_budget_remaining,
                   backoff_elapsed, guardrail_triggered, drain_complete,
                   restart_count>>

\* BugHeartbeatRecovery: the OLD code (pre-fix).
\* Only dispatches Turn_succeeded, NOT Manual_reconcile_cleared.
\* manual_reconcile_required stays TRUE — the one-way trap.
BugHeartbeatRecovery ==
    /\ NotTerminal /\ fiber_alive
    /\ manual_reconcile_required
    /\ heartbeat_healthy' = TRUE
    /\ turn_healthy' = TRUE
    /\ manual_reconcile_required' = TRUE  \* BUG: not cleared
    /\ UNCHANGED <<fiber_alive, compaction_active, handoff_active,
                   operator_paused, stop_requested, restart_budget_remaining,
                   backoff_elapsed, guardrail_triggered, drain_complete,
                   restart_count>>

CompactionStarted ==
    /\ NotTerminal /\ fiber_alive
    /\ ~compaction_active /\ ~handoff_active
    /\ compaction_active' = TRUE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete, restart_count>>

CompactionCompleted ==
    /\ NotTerminal /\ compaction_active
    /\ compaction_active' = FALSE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete, restart_count>>

HandoffStarted ==
    /\ NotTerminal /\ fiber_alive
    /\ ~handoff_active /\ ~compaction_active
    /\ handoff_active' = TRUE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required, compaction_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete, restart_count>>

HandoffCompleted ==
    /\ NotTerminal /\ handoff_active
    /\ handoff_active' = FALSE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required, compaction_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete, restart_count>>

OperatorPause ==
    /\ NotTerminal /\ fiber_alive
    /\ operator_paused' = TRUE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required, compaction_active, handoff_active,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete, restart_count>>

OperatorResume ==
    /\ NotTerminal /\ operator_paused
    /\ operator_paused' = FALSE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required, compaction_active, handoff_active,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete, restart_count>>

StopRequested ==
    /\ NotTerminal /\ ~stop_requested
    /\ stop_requested' = TRUE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required, compaction_active, handoff_active,
                   operator_paused, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete, restart_count>>

DrainCompleteEv ==
    /\ NotTerminal /\ stop_requested /\ ~drain_complete
    /\ ~compaction_active /\ ~handoff_active
    /\ drain_complete' = TRUE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required, compaction_active, handoff_active,
                   operator_paused, stop_requested, restart_budget_remaining,
                   backoff_elapsed, guardrail_triggered, restart_count>>

FiberTerminated ==
    /\ NotTerminal /\ fiber_alive
    /\ fiber_alive' = FALSE
    /\ UNCHANGED <<heartbeat_healthy, turn_healthy, manual_reconcile_required,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete, restart_count>>

FiberStarted ==
    /\ NotTerminal /\ ~fiber_alive /\ restart_budget_remaining
    /\ fiber_alive' = TRUE
    /\ heartbeat_healthy' = TRUE
    /\ turn_healthy' = TRUE
    /\ manual_reconcile_required' = FALSE  \* Fiber restart clears reconcile
    /\ compaction_active' = FALSE
    /\ handoff_active' = FALSE
    /\ backoff_elapsed' = FALSE
    /\ guardrail_triggered' = FALSE
    /\ drain_complete' = FALSE
    /\ stop_requested' = FALSE
    /\ UNCHANGED <<operator_paused, restart_budget_remaining, restart_count>>

SupervisorRestartAttempt ==
    /\ NotTerminal
    /\ ~fiber_alive /\ restart_budget_remaining
    /\ restart_count < MaxRestarts
    /\ backoff_elapsed' = TRUE
    /\ restart_count' = restart_count + 1
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required, compaction_active, handoff_active,
                   operator_paused, stop_requested, restart_budget_remaining,
                   guardrail_triggered, drain_complete>>

RestartBudgetExhausted ==
    /\ NotTerminal /\ restart_budget_remaining
    /\ restart_budget_remaining' = FALSE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required, compaction_active, handoff_active,
                   operator_paused, stop_requested, backoff_elapsed,
                   guardrail_triggered, drain_complete, restart_count>>

GuardrailStop ==
    /\ NotTerminal /\ fiber_alive
    /\ guardrail_triggered' = TRUE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required, compaction_active, handoff_active,
                   operator_paused, stop_requested, restart_budget_remaining,
                   backoff_elapsed, drain_complete, restart_count>>

\* ── Next State (FIXED code) ──────────────────────────────

Next ==
    \/ HeartbeatOk        \/ HeartbeatFailed
    \/ TurnSucceeded      \/ TurnFailed
    \/ ManualReconcileRequired
    \/ ManualReconcileCleared
    \/ HeartbeatRecovery
    \/ CompactionStarted  \/ CompactionCompleted
    \/ HandoffStarted     \/ HandoffCompleted
    \/ OperatorPause      \/ OperatorResume
    \/ StopRequested      \/ DrainCompleteEv
    \/ FiberTerminated    \/ FiberStarted
    \/ SupervisorRestartAttempt
    \/ RestartBudgetExhausted
    \/ GuardrailStop

\* Buggy Next: HeartbeatRecovery replaced with BugHeartbeatRecovery
\* and ManualReconcileCleared is removed (old code had no explicit clear
\* path during heartbeat recovery).
NextBuggy ==
    \/ HeartbeatOk        \/ HeartbeatFailed
    \/ TurnSucceeded      \/ TurnFailed
    \/ ManualReconcileRequired
    \/ ManualReconcileCleared     \* Operator can still manually clear
    \/ BugHeartbeatRecovery       \* BUG: does not clear reconcile
    \/ CompactionStarted  \/ CompactionCompleted
    \/ HandoffStarted     \/ HandoffCompleted
    \/ OperatorPause      \/ OperatorResume
    \/ StopRequested      \/ DrainCompleteEv
    \/ FiberTerminated    \/ FiberStarted
    \/ SupervisorRestartAttempt
    \/ RestartBudgetExhausted
    \/ GuardrailStop

\* ── Fairness ──────────────────────────────────────────────

Fairness ==
    /\ WF_vars(HeartbeatOk)
    /\ WF_vars(HeartbeatRecovery)
    /\ WF_vars(ManualReconcileCleared)
    /\ WF_vars(CompactionCompleted)
    /\ WF_vars(HandoffCompleted)
    /\ SF_vars(DrainCompleteEv)
    /\ WF_vars(FiberStarted)
    /\ WF_vars(SupervisorRestartAttempt)
    /\ WF_vars(FiberTerminated)

FairnessBuggy ==
    /\ WF_vars(HeartbeatOk)
    /\ WF_vars(BugHeartbeatRecovery)
    \* ManualReconcileCleared NOT included: operator action, not system-guaranteed.
    \* FiberTerminated NOT included: the bug scenario is a keeper that stays alive
    \* but stuck in Failing.  WF on FiberTerminated would allow the system to
    \* "escape" the trap via crash/restart, masking the liveness violation.
    \* In production, a fiber-alive keeper in Failing is the expected steady state
    \* for this bug — the fiber does not spontaneously crash.
    /\ WF_vars(CompactionCompleted)
    /\ WF_vars(HandoffCompleted)
    /\ SF_vars(DrainCompleteEv)
    /\ WF_vars(FiberStarted)
    /\ WF_vars(SupervisorRestartAttempt)

Spec == Init /\ [][Next]_vars /\ Fairness
SpecBuggy == Init /\ [][NextBuggy]_vars /\ FairnessBuggy

\* ── Safety Properties ─────────────────────────────────────

\* S1: Running requires no manual_reconcile_required
\* (Matches OCaml derive_phase: reconcile=true -> Failing)
RunningClearsManualReconcile ==
    [](Phase = "Running" => ~manual_reconcile_required)

\* S2: Dead is permanent
DeadIsForever == [](Phase = "Dead" => [](Phase = "Dead"))

\* S3: Stopped is permanent
StoppedIsForever == [](Phase = "Stopped" => [](Phase = "Stopped"))

\* S4: Running requires fiber_alive
RunningRequiresFiber == [](Phase = "Running" => fiber_alive)

\* ── Liveness Properties ───────────────────────────────────

\* L1: If manual_reconcile_required is set while the keeper is alive and
\* not terminal, the flag eventually gets cleared (either by HeartbeatRecovery,
\* operator ManualReconcileCleared, or FiberStarted after crash/restart).
\*
\* This is the property the old code VIOLATED — the one-way trap.
\* Without ManualReconcileCleared dispatch, a fiber_alive keeper with
\* manual_reconcile_required=true stays in Failing forever.
\*
\* The ~> allows the consequent to be reached via ANY path, including:
\*   - HeartbeatRecovery clears it directly (fix)
\*   - FiberTerminated + FiberStarted resets all conditions
\*   - Operator ManualReconcileCleared
\*   - Transition to Dead/Stopped (terminal, flag becomes irrelevant)
ManualReconcileLiveness ==
    (manual_reconcile_required /\ fiber_alive) ~>
        (~manual_reconcile_required \/ Phase \in TerminalPhases)

\* L2: A Failing keeper with a live fiber eventually exits Failing.
\* It may reach Running (recovery), Paused (operator-paused recovery),
\* Draining (stop), Crashed (fiber death), or terminal (Dead/Stopped).
\*
\* This is the property that detects the one-way trap: if
\* HeartbeatRecovery does not clear manual_reconcile_required,
\* the keeper stays Failing with fiber_alive forever.
FailingRecoveryLiveness ==
    (Phase = "Failing" /\ fiber_alive) ~> (Phase /= "Failing")

\* L3: Compacting eventually exits (inherited from base spec)
CompactingResolves == (Phase = "Compacting") ~> (Phase \in RecoverablePhases)

\* L4: HandingOff eventually exits
HandoffResolves == (Phase = "HandingOff") ~> (Phase \in RecoverablePhases)

\* L5: Draining eventually exits
DrainingResolves == (Phase = "Draining") ~> (Phase \in RecoverablePhases)

\* ── Deadlock Freedom ──────────────────────────────────────

NoDeadlockExceptTerminal ==
    Phase \notin TerminalPhases => ENABLED(Next)

\* ── Type Invariant ────────────────────────────────────────

TypeOK ==
    /\ fiber_alive \in BOOLEAN
    /\ heartbeat_healthy \in BOOLEAN
    /\ turn_healthy \in BOOLEAN
    /\ manual_reconcile_required \in BOOLEAN
    /\ compaction_active \in BOOLEAN
    /\ handoff_active \in BOOLEAN
    /\ operator_paused \in BOOLEAN
    /\ stop_requested \in BOOLEAN
    /\ restart_budget_remaining \in BOOLEAN
    /\ backoff_elapsed \in BOOLEAN
    /\ guardrail_triggered \in BOOLEAN
    /\ drain_complete \in BOOLEAN
    /\ restart_count \in 0..MaxRestarts+1
    /\ Phase \in {"Offline", "Running", "Failing", "Compacting",
                   "HandingOff", "Draining", "Paused", "Stopped",
                   "Crashed", "Restarting", "Dead"}

====
