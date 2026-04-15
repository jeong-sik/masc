---- MODULE KeeperTurnCycle ----
(***************************************************************************)
(* KeeperTurnCycle — runtime-aligned turn observation contract.            *)
(*                                                                         *)
(* This spec models the live per-turn observation that the OCaml runtime   *)
(* stores in [Keeper_registry.current_turn_observation]. It is not the old *)
(* "tool_call/side_effect/done" linear storyboard; the current runtime is  *)
(* a 3-axis machine:                                                        *)
(*   - turn_phase      : prompting | executing | compacting | finalizing   *)
(*   - decision_stage  : undecided | guard_ok | gate_rejected |            *)
(*                       tool_policy_selected                              *)
(*   - cascade_state   : idle | selecting | trying | done | exhausted      *)
(*                                                                         *)
(* Turn idle is represented by [turn_live = FALSE] plus cleared substate.  *)
(* The authoritative write points live in:                                  *)
(*   - keeper_registry.ml                                                  *)
(*   - keeper_agent_run.ml                                                 *)
(*   - keeper_unified_turn.ml                                              *)
(*   - keeper_guards.ml                                                    *)
(***************************************************************************)

EXTENDS TLC

VARIABLES
    turn_live,            \* current_turn_observation = Some _
    turn_phase,           \* Keeper_registry.turn_phase
    decision_stage,       \* Keeper_registry.decision_stage
    cascade_state,        \* Keeper_registry.cascade_state
    measurement_bound,    \* mark_turn_measurement already consumed
    selected_model_bound  \* selected_model = Some _

vars ==
    << turn_live, turn_phase, decision_stage, cascade_state,
       measurement_bound, selected_model_bound >>

TurnPhaseSet == {"idle", "prompting", "executing", "compacting", "finalizing"}
DecisionSet  == {"undecided", "guard_ok", "gate_rejected", "tool_policy_selected"}
CascadeSet   == {"idle", "selecting", "trying", "done", "exhausted"}
ActionSet    == {
    "StartTurn",
    "BindMeasurement",
    "GuardOk",
    "SelectToolPolicy",
    "GateRejected",
    "CascadeTrying",
    "CascadeDone",
    "CascadeExhausted",
    "EnterCompacting",
    "RetryAfterCompaction",
    "FinishTurn"
}
InvariantSet == {
    "NoLiveTurnClearsState",
    "IdleRequiresNotLive",
    "GateRejectedRequiresFinalizing",
    "SelectingRequiresToolPolicy",
    "ExecutingRequiresTrying",
    "CompactingRequiresTrying",
    "TerminalCascadeRequiresFinalizing"
}

TypeOK ==
    /\ turn_live \in BOOLEAN
    /\ turn_phase \in TurnPhaseSet
    /\ decision_stage \in DecisionSet
    /\ cascade_state \in CascadeSet
    /\ measurement_bound \in BOOLEAN
    /\ selected_model_bound \in BOOLEAN

Init ==
    /\ turn_live = FALSE
    /\ turn_phase = "idle"
    /\ decision_stage = "undecided"
    /\ cascade_state = "idle"
    /\ measurement_bound = FALSE
    /\ selected_model_bound = FALSE

\* ──────────────────────────────────────────────────────────────────────
\* Live turn installation
\* keeper_unified_turn.ml: mark_turn_started
\* ──────────────────────────────────────────────────────────────────────
StartTurn ==
    /\ ~turn_live
    /\ turn_live' = TRUE
    /\ turn_phase' = "prompting"
    /\ decision_stage' = "undecided"
    /\ cascade_state' = "idle"
    /\ measurement_bound' = FALSE
    /\ selected_model_bound' = FALSE

\* mark_turn_measurement
BindMeasurement ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ ~measurement_bound
    /\ measurement_bound' = TRUE
    /\ UNCHANGED <<turn_live, turn_phase, decision_stage,
                    cascade_state, selected_model_bound>>

\* keeper_unified_turn.ml elevates guard_ok when a measurement is present.
GuardOk ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ measurement_bound
    /\ decision_stage = "undecided"
    /\ decision_stage' = "guard_ok"
    /\ UNCHANGED <<turn_live, turn_phase, cascade_state,
                    measurement_bound, selected_model_bound>>

\* keeper_agent_run.ml: tool disclosure completes, selected policy becomes active.
\* Runtime allows this from undecided as well as guard_ok.
SelectToolPolicy ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ cascade_state = "idle"
    /\ decision_stage \in {"undecided", "guard_ok"}
    /\ decision_stage' = "tool_policy_selected"
    /\ cascade_state' = "selecting"
    /\ UNCHANGED <<turn_live, turn_phase, measurement_bound,
                    selected_model_bound>>

\* keeper_guards.ml: override/approval_required short-circuits the turn.
\* The runtime leaves cascade_state as-is (usually idle or selecting).
GateRejected ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ decision_stage \in {"undecided", "guard_ok", "tool_policy_selected"}
    /\ cascade_state \in {"idle", "selecting"}
    /\ turn_phase' = "finalizing"
    /\ decision_stage' = "gate_rejected"
    /\ UNCHANGED <<turn_live, cascade_state, measurement_bound,
                    selected_model_bound>>

\* keeper_unified_turn.ml: retry_loop sets Cascade_trying before OAS run.
CascadeTrying ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ decision_stage = "tool_policy_selected"
    /\ cascade_state = "selecting"
    /\ turn_phase' = "executing"
    /\ cascade_state' = "trying"
    /\ UNCHANGED <<turn_live, decision_stage, measurement_bound,
                    selected_model_bound>>

\* Successful cascade attempt chooses a model and enters finalizing.
CascadeDone ==
    /\ turn_live
    /\ turn_phase = "executing"
    /\ cascade_state = "trying"
    /\ turn_phase' = "finalizing"
    /\ cascade_state' = "done"
    /\ selected_model_bound' = TRUE
    /\ UNCHANGED <<turn_live, decision_stage, measurement_bound>>

\* Exhausted cascade also terminates the turn, without binding a model.
CascadeExhausted ==
    /\ turn_live
    /\ turn_phase = "executing"
    /\ cascade_state = "trying"
    /\ turn_phase' = "finalizing"
    /\ cascade_state' = "exhausted"
    /\ UNCHANGED <<turn_live, decision_stage, measurement_bound,
                    selected_model_bound>>

\* Overflow recovery enters explicit compaction while preserving the trying edge.
EnterCompacting ==
    /\ turn_live
    /\ turn_phase = "executing"
    /\ cascade_state = "trying"
    /\ turn_phase' = "compacting"
    /\ UNCHANGED <<turn_live, decision_stage, cascade_state,
                    measurement_bound, selected_model_bound>>

\* keeper_unified_turn.ml: prepare_turn_retry_after_compaction
\* Re-enters prompting with the measurement still bound, but clears the old
\* cascade attempt and selected model before the next retry.
RetryAfterCompaction ==
    /\ turn_live
    /\ turn_phase = "compacting"
    /\ cascade_state = "trying"
    /\ turn_phase' = "prompting"
    /\ decision_stage' = "guard_ok"
    /\ cascade_state' = "idle"
    /\ selected_model_bound' = FALSE
    /\ UNCHANGED <<turn_live, measurement_bound>>

\* keeper_unified_turn.ml finally block: mark_turn_finished clears live state.
FinishTurn ==
    /\ turn_live
    /\ turn_phase \in (TurnPhaseSet \ {"idle"})
    /\ turn_live' = FALSE
    /\ turn_phase' = "idle"
    /\ decision_stage' = "undecided"
    /\ cascade_state' = "idle"
    /\ measurement_bound' = FALSE
    /\ selected_model_bound' = FALSE

Next ==
    \/ StartTurn
    \/ BindMeasurement
    \/ GuardOk
    \/ SelectToolPolicy
    \/ GateRejected
    \/ CascadeTrying
    \/ CascadeDone
    \/ CascadeExhausted
    \/ EnterCompacting
    \/ RetryAfterCompaction
    \/ FinishTurn

Spec ==
    Init /\ [][Next]_vars /\ WF_vars(FinishTurn)

\* ──────────────────────────────────────────────────────────────────────
\* Invariants
\* ──────────────────────────────────────────────────────────────────────

NoLiveTurnClearsState ==
    ~turn_live =>
        /\ turn_phase = "idle"
        /\ decision_stage = "undecided"
        /\ cascade_state = "idle"
        /\ ~measurement_bound
        /\ ~selected_model_bound

IdleRequiresNotLive ==
    turn_phase = "idle" => ~turn_live

GateRejectedRequiresFinalizing ==
    decision_stage = "gate_rejected" => turn_phase = "finalizing"

SelectingRequiresToolPolicy ==
    cascade_state = "selecting" =>
        /\ turn_live
        /\ turn_phase = "prompting"
        /\ decision_stage = "tool_policy_selected"

ExecutingRequiresTrying ==
    turn_phase = "executing" =>
        /\ turn_live
        /\ cascade_state = "trying"
        /\ decision_stage = "tool_policy_selected"

CompactingRequiresTrying ==
    turn_phase = "compacting" =>
        /\ turn_live
        /\ cascade_state = "trying"
        /\ decision_stage = "tool_policy_selected"

TerminalCascadeRequiresFinalizing ==
    cascade_state \in {"done", "exhausted"} =>
        /\ turn_live
        /\ turn_phase = "finalizing"
        /\ decision_stage = "tool_policy_selected"

Safety ==
    /\ TypeOK
    /\ NoLiveTurnClearsState
    /\ IdleRequiresNotLive
    /\ GateRejectedRequiresFinalizing
    /\ SelectingRequiresToolPolicy
    /\ ExecutingRequiresTrying
    /\ CompactingRequiresTrying
    /\ TerminalCascadeRequiresFinalizing

LiveTurnEventuallyClears ==
    turn_live ~> ~turn_live

Liveness ==
    LiveTurnEventuallyClears

====
