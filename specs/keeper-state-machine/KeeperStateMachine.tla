---- MODULE KeeperStateMachine ----
\* Keeper 12-State Machine — TLA+ Formal Specification (RFC-0002)
\*
\* Models the deterministic core (Layer 2) of the keeper lifecycle.
\* Conditions (16 booleans) are primitive; Phase is derived via DerivePhase.
\* Events update conditions; DerivePhase projects the new phase.
\*
\* Verifies temporal properties that unit tests cannot:
\*   - Terminal permanence (Dead/Stopped are forever)
\*   - Deadlock freedom (non-terminal states always have enabled events)
\*   - Liveness (Failing, Overflowed eventually resolve)
\*   - Budget monotonicity (restart_budget_remaining never revives)
\*   - Overflowed transitions bounded (auto-compact or Paused, never loops)
\*
\* Mirrors: lib/keeper/keeper_state_machine.ml

EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxRestarts       \* Maximum restart attempts before Dead

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
    context_overflow,
    compact_retry_exhausted,
    restart_count

vars == <<fiber_alive, heartbeat_healthy, turn_healthy,
          manual_reconcile_required,
          compaction_active, handoff_active, operator_paused,
          stop_requested, restart_budget_remaining, backoff_elapsed,
          guardrail_triggered, drain_complete,
          context_overflow, compact_retry_exhausted,
          restart_count>>

\* ── Phase Derivation (priority-ordered, matching OCaml) ───

DerivePhase ==
    \* Stopped requires no buffer ops in flight (TLC deadlock fix)
    IF stop_requested /\ drain_complete
       /\ ~compaction_active /\ ~handoff_active THEN "Stopped"
    ELSE IF ~fiber_alive /\ ~restart_budget_remaining THEN "Dead"
    ELSE IF ~fiber_alive /\ restart_budget_remaining /\ backoff_elapsed THEN "Restarting"
    ELSE IF ~fiber_alive /\ restart_budget_remaining THEN "Crashed"
    ELSE IF stop_requested THEN "Draining"
    ELSE IF guardrail_triggered THEN "Failing"
    \* Overflow with retry latched promotes directly to Paused
    \* so operator intervention is required; else use Overflowed as a
    \* transient carrier for auto-compact dispatch.
    ELSE IF operator_paused
         \/ (context_overflow /\ compact_retry_exhausted) THEN "Paused"
    ELSE IF handoff_active THEN "HandingOff"
    ELSE IF compaction_active THEN "Compacting"
    ELSE IF context_overflow THEN "Overflowed"
    ELSE IF ~heartbeat_healthy \/ ~turn_healthy \/ manual_reconcile_required THEN "Failing"
    ELSE IF fiber_alive THEN "Running"
    ELSE "Offline"

Phase == DerivePhase

TerminalPhases == {"Stopped", "Dead"}
NotTerminal == Phase \notin TerminalPhases

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
    /\ context_overflow = FALSE
    /\ compact_retry_exhausted = FALSE
    /\ restart_count = 0

\* ── Events ────────────────────────────────────────────────

HeartbeatOk ==
    /\ NotTerminal /\ fiber_alive
    /\ heartbeat_healthy' = TRUE
    /\ UNCHANGED <<fiber_alive, turn_healthy, manual_reconcile_required,
                   compaction_active,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   restart_count>>

HeartbeatFailed ==
    /\ NotTerminal /\ fiber_alive
    /\ heartbeat_healthy' = FALSE
    /\ UNCHANGED <<fiber_alive, turn_healthy, manual_reconcile_required,
                   compaction_active,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   restart_count>>

\* NOTE: This action clears manual_reconcile_required, which DIFFERS from
\* the OCaml code (Turn_succeeded only sets turn_healthy=true, not
\* manual_reconcile_required=false).  Only Manual_reconcile_cleared and
\* Fiber_started clear it in OCaml.  The accurate model is in
\* KeeperReconcileLiveness.tla.  This spec retains the clearing behavior
\* to preserve backwards compatibility with existing property proofs
\* (RunningClearsManualReconcile + FailingResolves).
TurnSucceeded ==
    /\ NotTerminal /\ fiber_alive
    /\ turn_healthy' = TRUE
    /\ manual_reconcile_required' = FALSE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, compaction_active,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   restart_count>>

TurnFailed ==
    /\ NotTerminal /\ fiber_alive
    /\ turn_healthy' = FALSE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, manual_reconcile_required,
                   compaction_active,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   restart_count>>

ManualReconcileRequired ==
    /\ NotTerminal /\ fiber_alive
    /\ manual_reconcile_required' = TRUE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   restart_count>>

CompactionStarted ==
    /\ NotTerminal /\ fiber_alive
    /\ ~compaction_active /\ ~handoff_active
    /\ compaction_active' = TRUE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   restart_count>>

\* Successful compaction clears the overflow flags together with the
\* retry latch; the keeper returns to a fresh post-compact state.
CompactionCompleted ==
    /\ NotTerminal /\ compaction_active
    /\ compaction_active' = FALSE
    /\ context_overflow' = FALSE
    /\ compact_retry_exhausted' = FALSE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete, restart_count>>

HandoffStarted ==
    /\ NotTerminal /\ fiber_alive
    /\ ~handoff_active /\ ~compaction_active
    /\ handoff_active' = TRUE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required,
                   compaction_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   restart_count>>

HandoffCompleted ==
    /\ NotTerminal /\ handoff_active
    /\ handoff_active' = FALSE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required,
                   compaction_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   restart_count>>

OperatorPause ==
    /\ NotTerminal /\ fiber_alive
    /\ operator_paused' = TRUE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required,
                   compaction_active, handoff_active, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   restart_count>>

OperatorResume ==
    /\ NotTerminal /\ operator_paused
    /\ operator_paused' = FALSE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required,
                   compaction_active, handoff_active, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   restart_count>>

StopRequested ==
    /\ NotTerminal /\ ~stop_requested
    /\ stop_requested' = TRUE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required,
                   compaction_active, handoff_active, operator_paused,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   restart_count>>

DrainCompleteEv ==
    /\ NotTerminal /\ stop_requested /\ ~drain_complete
    /\ ~compaction_active /\ ~handoff_active  \* buffer ops must finish first
    /\ drain_complete' = TRUE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered,
                   context_overflow, compact_retry_exhausted,
                   restart_count>>

FiberTerminated ==
    /\ NotTerminal /\ fiber_alive
    /\ fiber_alive' = FALSE
    /\ UNCHANGED <<heartbeat_healthy, turn_healthy, manual_reconcile_required,
                   compaction_active,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   restart_count>>

FiberStarted ==
    /\ NotTerminal /\ ~fiber_alive /\ restart_budget_remaining
    /\ fiber_alive' = TRUE
    /\ heartbeat_healthy' = TRUE
    /\ turn_healthy' = TRUE
    /\ manual_reconcile_required' = FALSE
    /\ compaction_active' = FALSE
    /\ handoff_active' = FALSE
    /\ backoff_elapsed' = FALSE
    /\ guardrail_triggered' = FALSE
    /\ drain_complete' = FALSE
    /\ stop_requested' = FALSE  \* TLA+ liveness fix: restart contradicts stop
    /\ context_overflow' = FALSE
    /\ compact_retry_exhausted' = FALSE
    /\ UNCHANGED <<operator_paused,
                   restart_budget_remaining, restart_count>>

SupervisorRestartAttempt ==
    /\ NotTerminal
    /\ ~fiber_alive /\ restart_budget_remaining
    /\ restart_count < MaxRestarts
    /\ backoff_elapsed' = TRUE
    /\ restart_count' = restart_count + 1
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted>>

RestartBudgetExhausted ==
    /\ NotTerminal /\ restart_budget_remaining
    /\ restart_budget_remaining' = FALSE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   restart_count>>

GuardrailStop ==
    /\ NotTerminal /\ fiber_alive
    /\ guardrail_triggered' = TRUE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   drain_complete,
                   context_overflow, compact_retry_exhausted,
                   restart_count>>

\* ── Overflow Lifecycle Events ─────────────────────────────

\* Provider rejected the prompt.  The condition is set; DerivePhase
\* maps this to either Overflowed (first encounter) or Paused (if the
\* retry latch is already set).  Compacting keepers never see this
\* action (guarded by ~compaction_active) — that would mean a
\* runaway compaction, which the retry latch must catch instead.
ContextOverflowDetected ==
    /\ NotTerminal /\ fiber_alive
    /\ ~compaction_active
    /\ context_overflow' = TRUE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   compact_retry_exhausted, restart_count>>

\* Entry-action for Overflowed: promotes the keeper into Compacting
\* by flipping compaction_active.  No buffer op may already be in
\* flight; otherwise the ordering gets tangled.
AutoCompactTriggered ==
    /\ NotTerminal /\ fiber_alive
    /\ context_overflow /\ ~compaction_active /\ ~handoff_active
    /\ ~compact_retry_exhausted
    /\ compaction_active' = TRUE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   restart_count>>

\* Auto-compact budget exhausted.  Latched so DerivePhase routes the
\* keeper to Paused on the next overflow, breaking the Overflowed ↔
\* Compacting loop.
CompactRetryExhausted ==
    /\ NotTerminal /\ fiber_alive
    /\ context_overflow /\ ~compaction_active
    /\ ~compact_retry_exhausted
    /\ compact_retry_exhausted' = TRUE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, restart_count>>

\* Operator-driven compaction.  Same shape as AutoCompactTriggered but
\* also clears the retry latch so a fresh compaction sequence begins.
OperatorCompactRequested ==
    /\ NotTerminal /\ fiber_alive
    /\ ~compaction_active /\ ~handoff_active
    /\ compaction_active' = TRUE
    /\ compact_retry_exhausted' = FALSE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, restart_count>>

\* Last-resort: operator drops the keeper's context entirely via
\* [masc_keeper_clear].  Resets the overflow flags in-place without
\* touching [compaction_active].
OperatorClearRequested ==
    /\ NotTerminal
    /\ context_overflow' = FALSE
    /\ compact_retry_exhausted' = FALSE
    /\ manual_reconcile_required' = FALSE
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete, restart_count>>

\* ── Next State ────────────────────────────────────────────

Next ==
    \/ HeartbeatOk      \/ HeartbeatFailed
    \/ TurnSucceeded    \/ TurnFailed
    \/ ManualReconcileRequired
    \/ CompactionStarted \/ CompactionCompleted
    \/ HandoffStarted   \/ HandoffCompleted
    \/ OperatorPause    \/ OperatorResume
    \/ StopRequested    \/ DrainCompleteEv
    \/ FiberTerminated  \/ FiberStarted
    \/ SupervisorRestartAttempt
    \/ RestartBudgetExhausted
    \/ GuardrailStop
    \/ ContextOverflowDetected
    \/ AutoCompactTriggered
    \/ CompactRetryExhausted
    \/ OperatorCompactRequested
    \/ OperatorClearRequested

\* ── Fairness ──────────────────────────────────────────────

Fairness ==
    /\ WF_vars(HeartbeatOk)
    /\ WF_vars(ManualReconcileRequired)
    /\ WF_vars(CompactionCompleted)
    /\ WF_vars(HandoffCompleted)
    /\ SF_vars(DrainCompleteEv)     \* Strong fairness: drain fires even if intermittently enabled
    /\ WF_vars(FiberStarted)
    /\ WF_vars(SupervisorRestartAttempt)
    /\ WF_vars(FiberTerminated)     \* Fiber eventually terminates if crash conditions hold
    /\ WF_vars(AutoCompactTriggered) \* Overflowed always progresses toward Compacting

Spec == Init /\ [][Next]_vars /\ Fairness

\* ── Safety Properties ─────────────────────────────────────

\* S1: Dead is forever
DeadIsForever == [](Phase = "Dead" => [](Phase = "Dead"))

\* S2: Stopped is forever
StoppedIsForever == [](Phase = "Stopped" => [](Phase = "Stopped"))

\* S3: Budget never revives once exhausted
BudgetNeverRevives == [](~restart_budget_remaining => [](~restart_budget_remaining))

\* S4: stop_requested is NOT monotonic — FiberStarted resets it.
\*     (Removed: was violated by TLA+ liveness fix.)
\* StopMonotonicity == [](stop_requested => [](stop_requested))

\* S5: restart_count never decreases
RestartCountMonotonic == [][restart_count' >= restart_count]_vars

\* S6: Running requires fiber_alive
RunningRequiresFiber == [](Phase = "Running" => fiber_alive)

\* S7: Stopped requires both stop_requested and drain_complete
StoppedRequiresDrain == [](Phase = "Stopped" => (stop_requested /\ drain_complete))

\* S8: Dead requires no budget
DeadRequiresNoBudget == [](Phase = "Dead" => ~restart_budget_remaining)

\* S9: Running cannot retain a pending manual reconcile requirement.
RunningClearsManualReconcile == [](Phase = "Running" => ~manual_reconcile_required)

\* S10 (removed): "Compacting never re-enters Overflowed" was over-
\*      restrictive — a failed compaction legitimately leaves
\*      [context_overflow] set, which DerivePhase projects back to
\*      Overflowed so the retry loop can take another turn.  Recursive
\*      runaway is caught by the retry latch + OverflowedResolves
\*      instead.

\* S11: Overflowed is transient — each visit must progress to a different
\*      phase before a step completes.  Combined with AutoCompactTriggered
\*      fairness, this guarantees no keeper stays in Overflowed.
OverflowedNeverStutters ==
    [][(Phase = "Overflowed") => (Phase' /= "Overflowed")]_vars

\* ── Liveness Properties ───────────────────────────────────

\* Stable phases = non-buffer phases that represent a settled state.
\* Buffer phases are transient; liveness means they eventually exit.
StablePhases == {"Running", "Paused", "Crashed", "Stopped", "Dead", "Offline"}

\* L1: Failing eventually reaches a stable phase
FailingResolves == (Phase = "Failing") ~> (Phase \in StablePhases)

\* L2: Crashed with budget eventually progresses
CrashedRestartsEventually ==
    (Phase = "Crashed" /\ restart_budget_remaining) ~> (Phase \in StablePhases)

\* L3: Draining eventually resolves
DrainingResolves == (Phase = "Draining") ~> (Phase \in StablePhases)

\* L4: Compacting eventually exits
CompactingResolves == (Phase = "Compacting") ~> (Phase \in StablePhases)

\* L5: HandingOff eventually exits
HandoffResolves == (Phase = "HandingOff") ~> (Phase \in StablePhases)

\* L6: Overflowed eventually resolves — either the auto-compact succeeds
\*     (→ Running via Compacting) or the retry latch promotes to Paused.
OverflowedResolves ==
    (Phase = "Overflowed") ~> (Phase \in StablePhases \cup {"Compacting"})

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
    /\ context_overflow \in BOOLEAN
    /\ compact_retry_exhausted \in BOOLEAN
    /\ restart_count \in 0..MaxRestarts+1
    /\ Phase \in {"Offline", "Running", "Failing", "Overflowed",
                   "Compacting", "HandingOff", "Draining", "Paused",
                   "Stopped", "Crashed", "Restarting", "Dead"}

\* ── Bug Model: CompactionCompleted forgets to clear context_overflow ──
\*
\* Intent: demonstrate that the OverflowedResolves liveness property has
\* discriminating power.  If a future refactor breaks the condition-reset
\* contract in CompactionCompleted (for example, by forgetting to clear
\* context_overflow), the keeper will re-enter Overflowed on the very
\* next DerivePhase call even though compaction succeeded, looping
\* forever.  TLC must report a counterexample that violates
\* OverflowedResolves.
\*
\* Used by: KeeperOverflowRecovery-buggy.cfg (SPECIFICATION SpecBuggy)

BuggyCompactionCompleted ==
    /\ NotTerminal /\ compaction_active
    /\ compaction_active' = FALSE
    \* BUG: the primed values of context_overflow and compact_retry_exhausted
    \* are omitted, so those flags stay set after the compaction claims to
    \* have resolved the overflow.
    /\ UNCHANGED <<fiber_alive, heartbeat_healthy, turn_healthy,
                   manual_reconcile_required,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   restart_count>>

NextBuggy ==
    \/ HeartbeatOk      \/ HeartbeatFailed
    \/ TurnSucceeded    \/ TurnFailed
    \/ ManualReconcileRequired
    \/ CompactionStarted \/ BuggyCompactionCompleted  \* ← swapped in
    \/ HandoffStarted   \/ HandoffCompleted
    \/ OperatorPause    \/ OperatorResume
    \/ StopRequested    \/ DrainCompleteEv
    \/ FiberTerminated  \/ FiberStarted
    \/ SupervisorRestartAttempt
    \/ RestartBudgetExhausted
    \/ GuardrailStop
    \/ ContextOverflowDetected
    \/ AutoCompactTriggered
    \/ CompactRetryExhausted
    \/ OperatorCompactRequested
    \/ OperatorClearRequested

SpecBuggy == Init /\ [][NextBuggy]_vars /\ Fairness

====
