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
    launch_pending,
    fiber_alive,
    heartbeat_healthy,
    turn_healthy,
    context_within_budget,
    context_handoff_needed,
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
    restart_count,
    terminal_failure_latched

vars == <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
          context_within_budget, context_handoff_needed,
          compaction_active, handoff_active, operator_paused,
          stop_requested, restart_budget_remaining, backoff_elapsed,
          guardrail_triggered, drain_complete,
          context_overflow, compact_retry_exhausted,
          restart_count, terminal_failure_latched>>

\* ── Phase Derivation (priority-ordered, matching OCaml) ───

DerivePhase ==
    \* Stopped requires no buffer ops in flight (TLC deadlock fix)
    IF stop_requested /\ drain_complete
       /\ ~compaction_active /\ ~handoff_active THEN "Stopped"
    ELSE IF launch_pending /\ ~fiber_alive THEN "Offline"
    ELSE IF terminal_failure_latched THEN "Zombie"
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
    ELSE IF ~heartbeat_healthy \/ ~turn_healthy THEN "Failing"
    ELSE IF fiber_alive THEN "Running"
    ELSE "Offline"

Phase == DerivePhase

TerminalPhases == {"Stopped", "Dead", "Zombie"}
NotTerminal == Phase \notin TerminalPhases

\* ── Initial State ─────────────────────────────────────────

Init ==
    /\ launch_pending = FALSE
    /\ fiber_alive = TRUE
    /\ heartbeat_healthy = TRUE
    /\ turn_healthy = TRUE
    /\ context_within_budget = TRUE
    /\ context_handoff_needed = FALSE
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
    /\ terminal_failure_latched = FALSE

\* ── Events ────────────────────────────────────────────────

HeartbeatOk ==
    /\ NotTerminal /\ fiber_alive
    /\ heartbeat_healthy' = TRUE
    /\ UNCHANGED <<launch_pending, fiber_alive, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   compaction_active,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   restart_count, terminal_failure_latched>>

HeartbeatFailed ==
    /\ NotTerminal /\ fiber_alive
    /\ heartbeat_healthy' = FALSE
    /\ UNCHANGED <<launch_pending, fiber_alive, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   compaction_active,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   restart_count, terminal_failure_latched>>

TurnSucceeded ==
    /\ NotTerminal /\ fiber_alive
    /\ turn_healthy' = TRUE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy,
                   context_within_budget, context_handoff_needed,
                   compaction_active, handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   terminal_failure_latched, restart_count>>

TurnFailed ==
    /\ NotTerminal /\ fiber_alive
    /\ turn_healthy' = FALSE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy,
                   context_within_budget, context_handoff_needed, compaction_active,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   terminal_failure_latched, restart_count>>

ContextMeasured ==
    /\ NotTerminal /\ fiber_alive
    /\ context_handoff_needed' \in BOOLEAN
    /\ guardrail_triggered' \in BOOLEAN
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, compaction_active, handoff_active,
                   operator_paused, stop_requested, restart_budget_remaining,
                   backoff_elapsed, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   terminal_failure_latched, restart_count>>

CompactionStarted ==
    /\ NotTerminal /\ fiber_alive
    /\ ~compaction_active /\ ~handoff_active
    /\ compaction_active' = TRUE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   terminal_failure_latched, restart_count>>

\* Successful compaction with token savings (saved_tokens > 0).
\* Clears the overflow flags together with the retry latch; the keeper
\* returns to a fresh post-compact state.  Mirrors the OCaml
\* [Compaction_completed] arm when [before_tokens > after_tokens]
\* (lib/keeper/keeper_state_machine.ml §saved_tokens > 0).
CompactionCompletedWithSavings ==
    /\ NotTerminal /\ compaction_active
    /\ compaction_active' = FALSE
    /\ context_overflow' = FALSE
    /\ compact_retry_exhausted' = FALSE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete, terminal_failure_latched, restart_count>>

\* Noop completion (saved_tokens <= 0) — clears only [compaction_active];
\* [context_overflow] and [compact_retry_exhausted] are preserved so the
\* keeper re-enters Overflowed for the retry loop to escalate (stronger
\* compaction profile, handoff, operator alert).  Mirrors the OCaml fix
\* in #9988 that prevented the #9935 infinite noop loop (45-71
\* imminent-overflow events/day clearing the flag against unchanged
\* token counts).  Structurally identical to CompactionFailed; kept
\* separate so the action alphabet discriminates "attempted but no
\* savings" from "attempt errored", matching #8710 / R-A-8.
CompactionCompletedNoSavings ==
    /\ NotTerminal /\ compaction_active
    /\ compaction_active' = FALSE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   terminal_failure_latched, restart_count>>

\* Compaction attempt failed — clears the in-flight compaction flag but
\* deliberately leaves [context_overflow] set so the keeper re-enters
\* Overflowed for the retry loop to decide next step. The retry-budget
\* latch is owned by [CompactRetryExhausted] (separate event) once the
\* caller exhausts its allowance. Mirrors [Compaction_failed] in
\* [Keeper_state_machine.update_conditions]; added in #8578 to align the
\* model's event alphabet with the runtime so TLC can reason about
\* failure paths.
CompactionFailed ==
    /\ NotTerminal /\ compaction_active
    /\ compaction_active' = FALSE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   terminal_failure_latched, restart_count>>

HandoffStarted ==
    /\ NotTerminal /\ fiber_alive
    /\ ~handoff_active /\ ~compaction_active
    /\ handoff_active' = TRUE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   compaction_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   terminal_failure_latched, restart_count>>

HandoffCompleted ==
    /\ NotTerminal /\ handoff_active
    /\ handoff_active' = FALSE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   compaction_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   terminal_failure_latched, restart_count>>

\* Handoff attempt failed — clears the in-flight handoff flag, leaves
\* the rest unchanged. Mirrors [Handoff_failed] in
\* [Keeper_state_machine.update_conditions]; added in #8578 so TLC can
\* reason about handoff failure recovery.
HandoffFailed ==
    /\ NotTerminal /\ handoff_active
    /\ handoff_active' = FALSE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   compaction_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   terminal_failure_latched, restart_count>>

OperatorPause ==
    /\ NotTerminal /\ fiber_alive
    /\ operator_paused' = TRUE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   compaction_active, handoff_active, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   terminal_failure_latched, restart_count>>

OperatorResume ==
    /\ NotTerminal /\ operator_paused
    /\ operator_paused' = FALSE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   compaction_active, handoff_active, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   terminal_failure_latched, restart_count>>

StopRequested ==
    /\ NotTerminal /\ ~stop_requested
    /\ stop_requested' = TRUE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   compaction_active, handoff_active, operator_paused,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   terminal_failure_latched, restart_count>>

\* Operator-initiated stop. Same condition update as [StopRequested]
\* (sets [stop_requested]); the runtime distinguishes the two by a
\* [remove_meta] payload that controls whether the keeper meta file is
\* deleted on stop. The condition-level effect is identical, so TLC
\* sees the same successor states. Mirrors [Operator_stop] in
\* [Keeper_state_machine.update_conditions]; added in #8578 so the
\* model and runtime share the same event alphabet.
OperatorStop ==
    /\ NotTerminal /\ ~stop_requested
    /\ stop_requested' = TRUE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   compaction_active, handoff_active, operator_paused,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   terminal_failure_latched, restart_count>>

DrainCompleteEv ==
    /\ NotTerminal /\ stop_requested /\ ~drain_complete
    /\ ~compaction_active /\ ~handoff_active  \* buffer ops must finish first
    /\ drain_complete' = TRUE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered,
                   context_overflow, compact_retry_exhausted,
                   terminal_failure_latched, restart_count>>

FiberTerminated ==
    /\ NotTerminal /\ fiber_alive
    /\ fiber_alive' = FALSE
    /\ UNCHANGED <<launch_pending, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed, compaction_active,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   terminal_failure_latched, restart_count>>

FiberStarted ==
    /\ NotTerminal /\ ~fiber_alive /\ restart_budget_remaining
    /\ launch_pending' = FALSE
    /\ fiber_alive' = TRUE
    /\ heartbeat_healthy' = TRUE
    /\ turn_healthy' = TRUE
    /\ compaction_active' = FALSE
    /\ handoff_active' = FALSE
    /\ backoff_elapsed' = FALSE
    /\ guardrail_triggered' = FALSE
    /\ drain_complete' = FALSE
    /\ stop_requested' = FALSE  \* TLA+ liveness fix: restart contradicts stop
    /\ context_overflow' = FALSE
    /\ compact_retry_exhausted' = FALSE
    /\ terminal_failure_latched' = FALSE
    /\ UNCHANGED <<context_within_budget, context_handoff_needed, operator_paused,
                   restart_budget_remaining, restart_count>>

SupervisorRestartAttempt ==
    /\ NotTerminal
    /\ ~fiber_alive /\ restart_budget_remaining
    /\ restart_count < MaxRestarts
    /\ backoff_elapsed' = TRUE
    /\ restart_count' = restart_count + 1
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted>>

RestartBudgetExhausted ==
    /\ NotTerminal /\ restart_budget_remaining
    /\ restart_budget_remaining' = FALSE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   terminal_failure_latched, restart_count>>

GuardrailStop ==
    /\ NotTerminal /\ fiber_alive
    /\ guardrail_triggered' = TRUE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   drain_complete,
                   context_overflow, compact_retry_exhausted,
                   restart_count, terminal_failure_latched>>

TerminalFailureDetected ==
    /\ NotTerminal
    /\ terminal_failure_latched' = TRUE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
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
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   compact_retry_exhausted, terminal_failure_latched, restart_count>>

\* Entry-action for Overflowed: promotes the keeper into Compacting
\* by flipping compaction_active.  No buffer op may already be in
\* flight; otherwise the ordering gets tangled.
AutoCompactTriggered ==
    /\ NotTerminal /\ fiber_alive
    /\ context_overflow /\ ~compaction_active /\ ~handoff_active
    /\ ~compact_retry_exhausted
    /\ compaction_active' = TRUE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   terminal_failure_latched, restart_count>>

\* Auto-compact budget exhausted.  Latched so DerivePhase routes the
\* keeper to Paused on the next overflow, breaking the Overflowed ↔
\* Compacting loop.
CompactRetryExhausted ==
    /\ NotTerminal /\ fiber_alive
    /\ context_overflow /\ ~compaction_active
    /\ ~compact_retry_exhausted
    /\ compact_retry_exhausted' = TRUE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, terminal_failure_latched, restart_count>>

\* Operator-driven compaction.  Same shape as AutoCompactTriggered but
\* also clears the retry latch so a fresh compaction sequence begins.
OperatorCompactRequested ==
    /\ NotTerminal /\ fiber_alive
    /\ ~compaction_active /\ ~handoff_active
    /\ compaction_active' = TRUE
    /\ compact_retry_exhausted' = FALSE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, terminal_failure_latched, restart_count>>

\* Last-resort: operator drops the keeper's context entirely via
\* [masc_keeper_clear].  Resets the overflow flags in-place without
\* touching [compaction_active].
OperatorClearRequested ==
    /\ NotTerminal
    /\ context_overflow' = FALSE
    /\ compact_retry_exhausted' = FALSE
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   compaction_active, handoff_active, operator_paused,
                   stop_requested, restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete, terminal_failure_latched, restart_count>>

\* ── Next State ────────────────────────────────────────────

Next ==
    \/ HeartbeatOk      \/ HeartbeatFailed
    \/ TurnSucceeded    \/ TurnFailed
    \/ ContextMeasured
    \/ CompactionStarted
    \/ CompactionCompletedWithSavings \/ CompactionCompletedNoSavings
    \/ CompactionFailed
    \/ HandoffStarted   \/ HandoffCompleted    \/ HandoffFailed
    \/ OperatorPause    \/ OperatorResume
    \/ StopRequested    \/ OperatorStop        \/ DrainCompleteEv
    \/ FiberTerminated  \/ FiberStarted
    \/ SupervisorRestartAttempt
    \/ RestartBudgetExhausted
    \/ GuardrailStop
    \/ TerminalFailureDetected
    \/ ContextOverflowDetected
    \/ AutoCompactTriggered
    \/ CompactRetryExhausted
    \/ OperatorCompactRequested
    \/ OperatorClearRequested

\* ── Fairness ──────────────────────────────────────────────

Fairness ==
    /\ WF_vars(HeartbeatOk)
    /\ WF_vars(ContextMeasured)
    \* Weak fairness on the *savings* arm only.  This is NOT an
    \* "eventually saves" guarantee — CompactionCompletedNoSavings can
    \* fire and disable compaction_active, which in turn disables
    \* CompactionCompletedWithSavings.  WF here only forces the savings
    \* arm to fire in behaviors where it stays continuously enabled.
    \* The noop arm has no WF, modelling reality where stuck-overflow
    \* keepers loop through repeated noop compactions until escalation
    \* rather than self-resolve.
    /\ WF_vars(CompactionCompletedWithSavings)
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

\* S2b: Zombie is forever
\*   Structural absorption already enforced (every Next-action requires
\*   NotTerminal); this property makes the temporal invariant explicit
\*   so TLC catches a future regression that drops NotTerminal from any
\*   action.  Parity with S1/S2 — OCaml apply_event's terminal-state
\*   reject arm (keeper_state_machine.ml — `apply_event`'s
\*   `| Stopped | Dead | Zombie -> ... Error (Terminal_state {...})`
\*   branch; cited by symbol, not line — iter 64 N-2.a, converted in the
\*   iter 85 scattered-singles line-ref sweep) rejects all events on the
\*   same three terminal phases.
ZombieIsForever == [](Phase = "Zombie" => [](Phase = "Zombie"))

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

\* S9: Offline requires an explicit pre-start launch marker.
OfflineRequiresLaunchPending ==
    [](Phase = "Offline" => (launch_pending /\ ~fiber_alive))

\* S9b: Zombie requires the terminal_failure_latched marker.
\*   Mirror of S6/S7/S8/S9 — every terminal/non-default phase has an
\*   explicit one-way "Phase = X => condition" invariant (not iff —
\*   the reverse direction is intentionally outside this property's
\*   scope; DerivePhase priority handles entry). Zombie is reached
\*   only via TerminalFailureDetected which latches the flag. Once
\*   Zombie is entered the latch cannot clear (no action sets it
\*   false) so the invariant survives forever — combined with S2b
\*   this guarantees the absorbing semantics matches OCaml's
\*   apply_event terminal-state reject arm (keeper_state_machine.ml —
\*   `apply_event`'s `| Stopped | Dead | Zombie ->` branch).
ZombieRequiresTerminalFailureLatched ==
    [](Phase = "Zombie" => terminal_failure_latched)

\* S10 (removed): "Compacting never re-enters Overflowed" was over-
\*      restrictive — a failed compaction legitimately leaves
\*      [context_overflow] set, which DerivePhase projects back to
\*      Overflowed so the retry loop can take another turn.  Recursive
\*      runaway is caught by the retry latch + OverflowedResolves
\*      instead.

\* S11: CompactionClearsOverflow — action property: a *successful*
\*      compaction (token savings observed) must clear the overflow
\*      flags.  A failed compaction is allowed to leave [context_overflow]
\*      set so the retry loop can re-enter [Overflowed] or latch
\*      [Paused] via [compact_retry_exhausted].  Noop completion
\*      ([CompactionCompletedNoSavings], #9988 path) is *also* allowed
\*      to leave the flags set — the OCaml runtime escalates via
\*      operator alert / handoff once the retry budget exhausts.  See
\*      docs/tla-audit/ksm-compaction-completed-divergence-2026-05-12.md
\*      (iter 7 #14722) for the production reality and #8710 unblock
\*      path.
CompactionClearsOverflow ==
    [][CompactionCompletedWithSavings =>
         (~context_overflow' /\ ~compact_retry_exhausted')]_vars

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
\*     Target is StablePhases only (not Compacting) so the buggy cycle
\*     Overflowed↔Compacting is correctly detected as a liveness violation.
OverflowedResolves ==
    (Phase = "Overflowed") ~> (Phase \in StablePhases)

\* ── Deadlock Freedom ──────────────────────────────────────

NoDeadlockExceptTerminal ==
    Phase \notin TerminalPhases => ENABLED(Next)

\* ── Type Invariant ────────────────────────────────────────

TypeOK ==
    /\ launch_pending \in BOOLEAN
    /\ fiber_alive \in BOOLEAN
    /\ heartbeat_healthy \in BOOLEAN
    /\ turn_healthy \in BOOLEAN
    /\ context_within_budget \in BOOLEAN
    /\ context_handoff_needed \in BOOLEAN
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
    /\ terminal_failure_latched \in BOOLEAN
    /\ Phase \in {"Offline", "Running", "Failing", "Overflowed",
                   "Compacting", "HandingOff", "Draining", "Paused",
                   "Stopped", "Crashed", "Restarting", "Dead", "Zombie"}

\* ── Bug Model: CompactionCompleted forgets to clear context_overflow ──
\*
\* Intent: demonstrate that CompactionClearsOverflow has discriminating
\* power.  If a future refactor breaks the condition-reset contract in
\* CompactionCompleted (for example, by forgetting to clear context_overflow),
\* the keeper re-enters Overflowed on the very next DerivePhase call even
\* though compaction succeeded.  TLC must report a counterexample that
\* violates CompactionClearsOverflow (compaction completed but
\* context_overflow remains true).
\*
\* Used by: KeeperStateMachine-overflow-buggy.cfg (SPECIFICATION SpecBuggy)

BuggyCompactionCompleted ==
    /\ NotTerminal /\ compaction_active
    /\ compaction_active' = FALSE
    \* BUG: the primed values of context_overflow and compact_retry_exhausted
    \* are omitted, so those flags stay set after the compaction claims to
    \* have resolved the overflow.
    /\ UNCHANGED <<launch_pending, fiber_alive, heartbeat_healthy, turn_healthy,
                   context_within_budget, context_handoff_needed,
                   handoff_active, operator_paused, stop_requested,
                   restart_budget_remaining, backoff_elapsed,
                   guardrail_triggered, drain_complete,
                   context_overflow, compact_retry_exhausted,
                   terminal_failure_latched, restart_count>>

\* Buggy model witness: the buggy completion step above must still clear
\* the overflow flags.  Kept separate from [CompactionClearsOverflow] so
\* the clean spec can distinguish [CompactionCompleted] from the now-valid
\* [CompactionFailed] transition that preserves [context_overflow].
BuggyCompactionClearsOverflow ==
    [][BuggyCompactionCompleted =>
         (~context_overflow' /\ ~compact_retry_exhausted')]_vars

NextBuggy ==
    \/ HeartbeatOk      \/ HeartbeatFailed
    \/ TurnSucceeded    \/ TurnFailed
    \/ ContextMeasured
    \/ CompactionStarted \/ BuggyCompactionCompleted  \* ← swapped in
    \/ HandoffStarted   \/ HandoffCompleted
    \/ OperatorPause    \/ OperatorResume
    \/ StopRequested    \/ DrainCompleteEv
    \/ FiberTerminated  \/ FiberStarted
    \/ SupervisorRestartAttempt
    \/ RestartBudgetExhausted
    \/ GuardrailStop
    \/ TerminalFailureDetected
    \/ ContextOverflowDetected
    \/ AutoCompactTriggered
    \/ CompactRetryExhausted
    \/ OperatorCompactRequested
    \/ OperatorClearRequested

SpecBuggy == Init /\ [][NextBuggy]_vars /\ Fairness

====
