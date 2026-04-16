type tla_action =
  | Action_start_turn
  | Action_bind_measurement
  | Action_guard_ok
  | Action_select_tool_policy
  | Action_cascade_trying
  | Action_gate_rejected
  | Action_retry_after_compaction
  | Action_finish_turn

let all_tla_actions =
  [
    Action_start_turn;
    Action_bind_measurement;
    Action_guard_ok;
    Action_select_tool_policy;
    Action_cascade_trying;
    Action_gate_rejected;
    Action_retry_after_compaction;
    Action_finish_turn;
  ]

let tla_action_to_string = function
  | Action_start_turn -> "StartTurn"
  | Action_bind_measurement -> "BindMeasurement"
  | Action_guard_ok -> "GuardOk"
  | Action_select_tool_policy -> "SelectToolPolicy"
  | Action_cascade_trying -> "CascadeTrying"
  | Action_gate_rejected -> "GateRejected"
  | Action_retry_after_compaction -> "RetryAfterCompaction"
  | Action_finish_turn -> "FinishTurn"

let tla_action_of_string = function
  | "StartTurn" -> Some Action_start_turn
  | "BindMeasurement" -> Some Action_bind_measurement
  | "GuardOk" -> Some Action_guard_ok
  | "SelectToolPolicy" -> Some Action_select_tool_policy
  | "CascadeTrying" -> Some Action_cascade_trying
  | "GateRejected" -> Some Action_gate_rejected
  | "RetryAfterCompaction" -> Some Action_retry_after_compaction
  | "FinishTurn" -> Some Action_finish_turn
  | _ -> None

type invariant_key =
  | Inv_no_live_turn_clears_decision
  | Inv_idle_requires_undecided
  | Inv_guard_ok_requires_measurement
  | Inv_decision_boundary_requires_measurement
  | Inv_gate_rejected_requires_finalizing
  | Inv_non_idle_cascade_requires_decision_boundary
  | Inv_selecting_requires_prompting

let all_invariant_keys =
  [
    Inv_no_live_turn_clears_decision;
    Inv_idle_requires_undecided;
    Inv_guard_ok_requires_measurement;
    Inv_decision_boundary_requires_measurement;
    Inv_gate_rejected_requires_finalizing;
    Inv_non_idle_cascade_requires_decision_boundary;
    Inv_selecting_requires_prompting;
  ]

let invariant_key_to_string = function
  | Inv_no_live_turn_clears_decision -> "NoLiveTurnClearsDecision"
  | Inv_idle_requires_undecided -> "IdleRequiresUndecided"
  | Inv_guard_ok_requires_measurement -> "GuardOkRequiresMeasurement"
  | Inv_decision_boundary_requires_measurement ->
      "DecisionBoundaryRequiresMeasurement"
  | Inv_gate_rejected_requires_finalizing -> "GateRejectedRequiresFinalizing"
  | Inv_non_idle_cascade_requires_decision_boundary ->
      "NonIdleCascadeRequiresDecisionBoundary"
  | Inv_selecting_requires_prompting -> "SelectingRequiresPrompting"

let invariant_key_of_string = function
  | "NoLiveTurnClearsDecision" -> Some Inv_no_live_turn_clears_decision
  | "IdleRequiresUndecided" -> Some Inv_idle_requires_undecided
  | "GuardOkRequiresMeasurement" -> Some Inv_guard_ok_requires_measurement
  | "DecisionBoundaryRequiresMeasurement" ->
      Some Inv_decision_boundary_requires_measurement
  | "GateRejectedRequiresFinalizing" ->
      Some Inv_gate_rejected_requires_finalizing
  | "NonIdleCascadeRequiresDecisionBoundary" ->
      Some Inv_non_idle_cascade_requires_decision_boundary
  | "SelectingRequiresPrompting" -> Some Inv_selecting_requires_prompting
  | _ -> None
