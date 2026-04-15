---- MODULE KeeperDecisionPipeline ----
(***************************************************************************)
(* KeeperDecisionPipeline — runtime-aligned decision stage contract.       *)
(*                                                                         *)
(* This spec models the decision-stage projection stored in                *)
(* [Keeper_registry.current_turn_observation.decision_stage]. The current  *)
(* runtime no longer uses the old Thompson/tool_count feedback loop that   *)
(* an earlier TLA draft described. Instead, the live decision pipeline is  *)
(* a narrow per-turn contract driven by four write points:                 *)
(*   - mark_turn_started                    → undecided                    *)
(*   - mark_turn_measurement + guard pass   → guard_ok                     *)
(*   - keeper_agent_run tool disclosure     → tool_policy_selected         *)
(*   - keeper_guards override/approval gate → gate_rejected               *)
(* plus retry/finalize resets.                                              *)
(***************************************************************************)

VARIABLES
    turn_live,          \* current_turn_observation = Some _
    turn_phase,         \* Keeper_registry.turn_phase
    decision_stage,     \* Keeper_registry.decision_stage
    cascade_state,      \* Keeper_registry.cascade_state
    measurement_bound   \* mark_turn_measurement already consumed

vars == <<turn_live, turn_phase, decision_stage, cascade_state, measurement_bound>>

TurnPhaseSet == {"idle", "prompting", "executing", "compacting", "finalizing"}
DecisionSet  == {"undecided", "guard_ok", "gate_rejected", "tool_policy_selected"}
CascadeSet   == {"idle", "selecting", "trying", "done", "exhausted"}
ActionSet    == {
    "StartTurn",
    "BindMeasurement",
    "GuardOk",
    "SelectToolPolicy",
    "GateRejected",
    "RetryAfterCompaction",
    "FinishTurn"
}
InvariantSet == {
    "NoLiveTurnClearsDecision",
    "IdleRequiresUndecided",
    "GuardOkRequiresMeasurement",
    "GateRejectedRequiresFinalizing",
    "NonIdleCascadeRequiresToolPolicy",
    "SelectingRequiresPrompting"
}

TypeOK ==
    /\ turn_live \in BOOLEAN
    /\ turn_phase \in TurnPhaseSet
    /\ decision_stage \in DecisionSet
    /\ cascade_state \in CascadeSet
    /\ measurement_bound \in BOOLEAN

Init ==
    /\ turn_live = FALSE
    /\ turn_phase = "idle"
    /\ decision_stage = "undecided"
    /\ cascade_state = "idle"
    /\ measurement_bound = FALSE

StartTurn ==
    /\ ~turn_live
    /\ turn_live' = TRUE
    /\ turn_phase' = "prompting"
    /\ decision_stage' = "undecided"
    /\ cascade_state' = "idle"
    /\ measurement_bound' = FALSE

BindMeasurement ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ ~measurement_bound
    /\ measurement_bound' = TRUE
    /\ UNCHANGED <<turn_live, turn_phase, decision_stage, cascade_state>>

GuardOk ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ measurement_bound
    /\ decision_stage = "undecided"
    /\ decision_stage' = "guard_ok"
    /\ UNCHANGED <<turn_live, turn_phase, cascade_state, measurement_bound>>

\* Runtime allows policy selection directly from undecided or from guard_ok.
SelectToolPolicy ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ cascade_state = "idle"
    /\ decision_stage \in {"undecided", "guard_ok"}
    /\ decision_stage' = "tool_policy_selected"
    /\ cascade_state' = "selecting"
    /\ UNCHANGED <<turn_live, turn_phase, measurement_bound>>

\* Guards can short-circuit while the turn is still in prompting.
GateRejected ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ decision_stage \in {"undecided", "guard_ok", "tool_policy_selected"}
    /\ turn_phase' = "finalizing"
    /\ decision_stage' = "gate_rejected"
    /\ UNCHANGED <<turn_live, cascade_state, measurement_bound>>

\* Overflow retry resets the decision lane to a fresh post-guard posture.
RetryAfterCompaction ==
    /\ turn_live
    /\ turn_phase = "compacting"
    /\ decision_stage = "tool_policy_selected"
    /\ decision_stage' = "guard_ok"
    /\ cascade_state' = "idle"
    /\ turn_phase' = "prompting"
    /\ UNCHANGED <<turn_live, measurement_bound>>

FinishTurn ==
    /\ turn_live
    /\ turn_phase \in (TurnPhaseSet \ {"idle"})
    /\ turn_live' = FALSE
    /\ turn_phase' = "idle"
    /\ decision_stage' = "undecided"
    /\ cascade_state' = "idle"
    /\ measurement_bound' = FALSE

Next ==
    \/ StartTurn
    \/ BindMeasurement
    \/ GuardOk
    \/ SelectToolPolicy
    \/ GateRejected
    \/ RetryAfterCompaction
    \/ FinishTurn

Spec ==
    Init /\ [][Next]_vars /\ WF_vars(FinishTurn)

NoLiveTurnClearsDecision ==
    ~turn_live =>
        /\ turn_phase = "idle"
        /\ decision_stage = "undecided"
        /\ cascade_state = "idle"
        /\ ~measurement_bound

IdleRequiresUndecided ==
    turn_phase = "idle" => decision_stage = "undecided"

GuardOkRequiresMeasurement ==
    decision_stage = "guard_ok" =>
        /\ turn_live
        /\ turn_phase = "prompting"
        /\ measurement_bound
        /\ cascade_state = "idle"

GateRejectedRequiresFinalizing ==
    decision_stage = "gate_rejected" =>
        /\ turn_live
        /\ turn_phase = "finalizing"

NonIdleCascadeRequiresToolPolicy ==
    cascade_state \in {"selecting", "trying", "done", "exhausted"} =>
        decision_stage = "tool_policy_selected"

SelectingRequiresPrompting ==
    cascade_state = "selecting" =>
        /\ turn_live
        /\ turn_phase = "prompting"

Safety ==
    /\ TypeOK
    /\ NoLiveTurnClearsDecision
    /\ IdleRequiresUndecided
    /\ GuardOkRequiresMeasurement
    /\ GateRejectedRequiresFinalizing
    /\ NonIdleCascadeRequiresToolPolicy
    /\ SelectingRequiresPrompting

DecisionEventuallyClears ==
    decision_stage /= "undecided" ~> decision_stage = "undecided"

Liveness ==
    DecisionEventuallyClears

====
