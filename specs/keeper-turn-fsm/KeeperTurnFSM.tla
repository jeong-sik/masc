---- MODULE KeeperTurnFSM ----
\* Step 7 of the bloodflow restoration plan.
\*
\* Mirrors the OCaml [Keeper_turn_fsm] type module landed in Step 4a
\* (lib/keeper/keeper_turn_fsm.{ml,mli}). The spec models the single-axis
\* turn lifecycle, the receipt write that closes it, and the
\* externally-observable stop signal. The point is to prove that no
\* terminal state silently drops the receipt or rewrites a Cancelled
\* turn as Done.
\*
\* Sibling specs cover orthogonal angles:
\*   - KeeperTurnCycle (3-axis: turn_phase / decision_stage / cascade_state)
\*     models cross-axis synchronization for the *live* observation record.
\*   - KeeperOASAdvanced models the OAS bridge cancel/error boundary.
\*
\* This spec is the COMPOSITE of "turn state" + "receipt outcome" + "stop
\* signal" — the only place in the corpus where ReceiptIsAuthoritative
\* and StopSignalRespected are jointly checkable. That is the
\* load-bearing reason it is not redundant with KeeperTurnCycle (which
\* has no receipt axis) or KeeperOASAdvanced (which has no per-turn
\* state lattice).
\*
\* OCaml <-> TLA+ mapping:
\*
\*   spec value           | OCaml constructor                          | source
\*   ---------------------+--------------------------------------------+-------
\*   "idle"               | Keeper_turn_fsm.Idle                       | keeper_turn_fsm.mli
\*   "phase_gating"       | Keeper_turn_fsm.Phase_gating               |
\*   "cascade_routing"    | Keeper_turn_fsm.Cascade_routing            |
\*   "awaiting_provider"  | Keeper_turn_fsm.Awaiting_provider          |
\*   "streaming"          | Keeper_turn_fsm.Streaming                  |
\*   "awaiting_tool"      | Keeper_turn_fsm.Awaiting_tool_result       |
\*   "completing"         | Keeper_turn_fsm.Completing                 |
\*   "done"               | Keeper_turn_fsm.Done                       |
\*   "failed"             | Keeper_turn_fsm.Failed _                   |
\*   "cancelled"          | Keeper_turn_fsm.Cancelled _                |
\*
\*   "receipt_unset"      | (no record_pre_dispatch_terminal_observation yet)
\*   "receipt_skipped"    | record_pre_dispatch_terminal_observation outcome=skipped
\*   "receipt_done"       | append_receipt outcome=done
\*   "receipt_failed"     | append_receipt outcome=failed
\*   "receipt_cancelled"  | append_receipt outcome=cancelled
\*
\*   stop_signaled        | supervisor stop / fleet shutdown / phase
\*                          gate close — any externally observable
\*                          cooperative-cancel request.
\*
\* Out-of-scope:
\*   - failure_reason / cancel_reason carriers (the OCaml record fields
\*     don't change the FSM shape, only the label).
\*   - phase gate cascade selection internals (covered by KeeperTurnCycle).
\*   - tool dispatch graph below the turn-facing projection.

EXTENDS TLC

VARIABLES
    turn_state,        \* one of TurnStateSet
    receipt_outcome,   \* one of ReceiptOutcomeSet
    stop_signaled      \* BOOLEAN — supervisor / fleet shutdown raised

vars == << turn_state, receipt_outcome, stop_signaled >>

TurnStateSet ==
    { "idle",
      "phase_gating",
      "cascade_routing",
      "awaiting_provider",
      "streaming",
      "awaiting_tool",
      "completing",
      "done",
      "failed",
      "cancelled" }

\* Active (non-terminal) states from which cancellation is observable.
ActiveStateSet ==
    { "phase_gating",
      "cascade_routing",
      "awaiting_provider",
      "streaming",
      "awaiting_tool",
      "completing" }

TerminalStateSet == { "done", "failed", "cancelled" }

ReceiptOutcomeSet ==
    { "receipt_unset",
      "receipt_skipped",
      "receipt_done",
      "receipt_failed",
      "receipt_cancelled" }

TypeOK ==
    /\ turn_state \in TurnStateSet
    /\ receipt_outcome \in ReceiptOutcomeSet
    /\ stop_signaled \in BOOLEAN

Init ==
    /\ turn_state = "idle"
    /\ receipt_outcome = "receipt_unset"
    /\ stop_signaled = FALSE

\* ─────────────────────────────────────────────────────────────────────
\* Forward transitions (the "happy path" + structured failures)
\* ─────────────────────────────────────────────────────────────────────

\* run_keeper_cycle entry → phase gate evaluation. Stop signal must not
\* already be raised — once a stop is in flight, no new turn starts.
StartTurn ==
    /\ turn_state = "idle"
    /\ ~stop_signaled
    /\ turn_state' = "phase_gating"
    /\ UNCHANGED << receipt_outcome, stop_signaled >>

\* Phase gate skip — pre-dispatch terminal observation, outcome = skipped.
\* Maps to keeper_unified_turn.ml:99-126 (non-executable phase early exit;
\* PR #11154 wired keeper_turn_id; action label added to emit_transition).
PhaseGateSkip ==
    /\ turn_state = "phase_gating"
    /\ ~stop_signaled
    /\ turn_state' = "done"
    /\ receipt_outcome' = "receipt_skipped"
    /\ UNCHANGED stop_signaled

\* Phase gate allows turn → cascade routing.
\* Forward edges only fire when no stop signal is in flight; once stop
\* is raised, HonorStopSignal is the only legal transition out of an
\* active state.
PhaseGateOk ==
    /\ turn_state = "phase_gating"
    /\ ~stop_signaled
    /\ turn_state' = "cascade_routing"
    /\ UNCHANGED << receipt_outcome, stop_signaled >>

\* Cascade chose a provider, dispatch begins.
CascadeRouted ==
    /\ turn_state = "cascade_routing"
    /\ ~stop_signaled
    /\ turn_state' = "awaiting_provider"
    /\ UNCHANGED << receipt_outcome, stop_signaled >>

\* All cascade attempts exhausted (no provider can serve this turn).
\* Receipt outcome = failed (failure_reason = Cascade_unavailable).
CascadeUnavailable ==
    /\ turn_state = "cascade_routing"
    /\ ~stop_signaled
    /\ turn_state' = "failed"
    /\ receipt_outcome' = "receipt_failed"
    /\ UNCHANGED stop_signaled

\* Provider responds → start streaming.
ProviderResponded ==
    /\ turn_state = "awaiting_provider"
    /\ ~stop_signaled
    /\ turn_state' = "streaming"
    /\ UNCHANGED << receipt_outcome, stop_signaled >>

\* Provider timeout past the cooperative-cancel deadline. Treated as
\* Cancelled because Step 4a names cancel_reason = Provider_timeout.
ProviderTimeout ==
    /\ turn_state = "awaiting_provider"
    /\ ~stop_signaled
    /\ turn_state' = "cancelled"
    /\ receipt_outcome' = "receipt_cancelled"
    /\ UNCHANGED stop_signaled

\* Stream emits a tool call → wait for tool result.
StreamYieldsTool ==
    /\ turn_state = "streaming"
    /\ ~stop_signaled
    /\ turn_state' = "awaiting_tool"
    /\ UNCHANGED << receipt_outcome, stop_signaled >>

\* Tool result returned → resume streaming.
ToolReturned ==
    /\ turn_state = "awaiting_tool"
    /\ ~stop_signaled
    /\ turn_state' = "streaming"
    /\ UNCHANGED << receipt_outcome, stop_signaled >>

\* Stream finishes (no more tool calls / model emitted stop_reason).
StreamComplete ==
    /\ turn_state = "streaming"
    /\ ~stop_signaled
    /\ turn_state' = "completing"
    /\ UNCHANGED << receipt_outcome, stop_signaled >>

\* Contract validation passes → terminal Done.
ContractOk ==
    /\ turn_state = "completing"
    /\ ~stop_signaled
    /\ turn_state' = "done"
    /\ receipt_outcome' = "receipt_done"
    /\ UNCHANGED stop_signaled

\* Contract violation (passive_only / needs_execution_progress).
\* Receipt outcome = failed (failure_reason = Tool_contract_violation).
ContractViolation ==
    /\ turn_state = "completing"
    /\ ~stop_signaled
    /\ turn_state' = "failed"
    /\ receipt_outcome' = "receipt_failed"
    /\ UNCHANGED stop_signaled

\* Receipt I/O failure during a happy-path completion. Models
\* Failure_receipt_lost — keeper_execution_receipt.append returning
\* Error and Step 3 of the plan promoting that to a structured failure.
ReceiptLost ==
    /\ turn_state = "completing"
    /\ ~stop_signaled
    /\ turn_state' = "failed"
    /\ receipt_outcome' = "receipt_failed"
    /\ UNCHANGED stop_signaled

\* Supervisor / fleet shutdown / phase gate close raises the stop signal
\* asynchronously. Modelled separately from the actual cancellation step
\* so the invariant can observe the "signal raised but not yet honored"
\* window.
SupervisorRequestsStop ==
    /\ ~stop_signaled
    /\ turn_state \in ActiveStateSet
    /\ stop_signaled' = TRUE
    /\ UNCHANGED << turn_state, receipt_outcome >>

\* Honored cooperative-cancel: the FSM observes the stop signal and
\* transitions to cancelled with a receipt outcome of cancelled.
HonorStopSignal ==
    /\ stop_signaled
    /\ turn_state \in ActiveStateSet
    /\ turn_state' = "cancelled"
    /\ receipt_outcome' = "receipt_cancelled"
    /\ UNCHANGED stop_signaled

\* ─────────────────────────────────────────────────────────────────────
\* Bug actions (used only by SpecBuggy)
\* ─────────────────────────────────────────────────────────────────────

\* [BUG MODEL #1] Catch-all swallows the Cancelled exception and records
\* the turn as receipt_done. Models the Fun.protect / safe_emit_turn_end
\* swallow at keeper_agent_run.ml:157-164 that Step 5 of the plan
\* removes. Violates StopSignalRespected.
StopSignalSwallowedAsDone ==
    /\ stop_signaled
    /\ turn_state \in ActiveStateSet
    /\ turn_state' = "done"
    /\ receipt_outcome' = "receipt_done"
    /\ UNCHANGED stop_signaled

\* [BUG MODEL #2] Receipt append failure is logged WARN-only and the
\* turn still terminates as done. Models the silent fail point that
\* Step 3 of the plan promotes to a Failure_receipt_lost variant.
\* Violates EveryTurnHasTerminalReceipt.
SilentReceiptDrop ==
    /\ turn_state = "completing"
    /\ turn_state' = "done"
    /\ receipt_outcome' = "receipt_unset"
    /\ UNCHANGED stop_signaled

\* Terminal stutter — once a turn reaches a terminal state with a
\* receipt outcome bound, the lifecycle is closed.
TerminalStutter ==
    /\ turn_state \in TerminalStateSet
    /\ UNCHANGED vars

Next ==
    \/ StartTurn
    \/ PhaseGateSkip
    \/ PhaseGateOk
    \/ CascadeRouted
    \/ CascadeUnavailable
    \/ ProviderResponded
    \/ ProviderTimeout
    \/ StreamYieldsTool
    \/ ToolReturned
    \/ StreamComplete
    \/ ContractOk
    \/ ContractViolation
    \/ ReceiptLost
    \/ SupervisorRequestsStop
    \/ HonorStopSignal
    \/ TerminalStutter

NextBuggy ==
    \/ Next
    \/ StopSignalSwallowedAsDone
    \/ SilentReceiptDrop

Fairness ==
    \* Liveness: the turn must eventually reach a terminal state.
    \* WF on the deterministic exit edges; SF on StreamComplete because
    \* the streaming ⇄ awaiting_tool oscillation alternates StreamComplete
    \* between enabled (in streaming) and disabled (in awaiting_tool).
    \* WF would let the oscillation spin forever — it requires the action
    \* to be *continuously* enabled. SF requires it to fire if it is
    \* *infinitely often* enabled, which the cycle satisfies.
    /\ WF_vars(StartTurn)
    /\ WF_vars(PhaseGateOk \/ PhaseGateSkip)
    /\ WF_vars(CascadeRouted \/ CascadeUnavailable)
    /\ WF_vars(ProviderResponded \/ ProviderTimeout)
    /\ SF_vars(StreamComplete)
    /\ WF_vars(ToolReturned)
    /\ WF_vars(ContractOk \/ ContractViolation \/ ReceiptLost)
    /\ WF_vars(HonorStopSignal)

Spec      == Init /\ [][Next]_vars      /\ Fairness
SpecBuggy == Init /\ [][NextBuggy]_vars  /\ Fairness

\* ─────────────────────────────────────────────────────────────────────
\* Safety invariants
\* ─────────────────────────────────────────────────────────────────────

\* Every terminal state must carry a receipt outcome. The whole point of
\* the bloodflow plan: a turn that left no receipt is invisible.
\* Caught by SilentReceiptDrop (bug #2).
EveryTurnHasTerminalReceipt ==
    turn_state \in TerminalStateSet => receipt_outcome /= "receipt_unset"

\* The receipt outcome must agree with the terminal state. Done means
\* the model wrote something; Failed means structured failure; Cancelled
\* means cooperative-cancel was respected.
ReceiptMatchesState ==
    /\ (turn_state = "done" =>
            receipt_outcome \in {"receipt_done", "receipt_skipped"})
    /\ (turn_state = "failed"    => receipt_outcome = "receipt_failed")
    /\ (turn_state = "cancelled" => receipt_outcome = "receipt_cancelled")

\* Once a stop is signaled, no new turn may quietly finish as Done
\* before the FSM has a chance to honor the cancel. Caught by
\* StopSignalSwallowedAsDone (bug #1).
StopSignalRespected ==
    (stop_signaled /\ turn_state \in TerminalStateSet) =>
        turn_state = "cancelled"

\* Receipt outcome reflects the FSM truth. If the receipt says "done" we
\* must actually be in done. We never pretend a failure or cancel was a
\* clean success.
ReceiptIsAuthoritative ==
    receipt_outcome = "receipt_done" => turn_state = "done"

Safety ==
    /\ TypeOK
    /\ EveryTurnHasTerminalReceipt
    /\ ReceiptMatchesState
    /\ StopSignalRespected
    /\ ReceiptIsAuthoritative

\* ─────────────────────────────────────────────────────────────────────
\* Liveness
\* ─────────────────────────────────────────────────────────────────────

\* Every started turn eventually reaches a terminal state. This is the
\* turn-side mirror of LiveTurnEventuallyClears in KeeperTurnCycle.
EveryTurnEventuallyTerminates ==
    (turn_state /= "idle") ~> (turn_state \in TerminalStateSet)

Liveness == EveryTurnEventuallyTerminates

====
