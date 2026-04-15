type tla_action =
  | Action_start_turn
  | Action_bind_measurement
  | Action_guard_ok
  | Action_select_tool_policy
  | Action_gate_rejected
  | Action_cascade_trying
  | Action_cascade_done
  | Action_cascade_exhausted
  | Action_enter_compacting
  | Action_retry_after_compaction
  | Action_finish_turn

let all_tla_actions =
  [
    Action_start_turn;
    Action_bind_measurement;
    Action_guard_ok;
    Action_select_tool_policy;
    Action_gate_rejected;
    Action_cascade_trying;
    Action_cascade_done;
    Action_cascade_exhausted;
    Action_enter_compacting;
    Action_retry_after_compaction;
    Action_finish_turn;
  ]

let tla_action_to_string = function
  | Action_start_turn -> "StartTurn"
  | Action_bind_measurement -> "BindMeasurement"
  | Action_guard_ok -> "GuardOk"
  | Action_select_tool_policy -> "SelectToolPolicy"
  | Action_gate_rejected -> "GateRejected"
  | Action_cascade_trying -> "CascadeTrying"
  | Action_cascade_done -> "CascadeDone"
  | Action_cascade_exhausted -> "CascadeExhausted"
  | Action_enter_compacting -> "EnterCompacting"
  | Action_retry_after_compaction -> "RetryAfterCompaction"
  | Action_finish_turn -> "FinishTurn"

let tla_action_of_string = function
  | "StartTurn" -> Some Action_start_turn
  | "BindMeasurement" -> Some Action_bind_measurement
  | "GuardOk" -> Some Action_guard_ok
  | "SelectToolPolicy" -> Some Action_select_tool_policy
  | "GateRejected" -> Some Action_gate_rejected
  | "CascadeTrying" -> Some Action_cascade_trying
  | "CascadeDone" -> Some Action_cascade_done
  | "CascadeExhausted" -> Some Action_cascade_exhausted
  | "EnterCompacting" -> Some Action_enter_compacting
  | "RetryAfterCompaction" -> Some Action_retry_after_compaction
  | "FinishTurn" -> Some Action_finish_turn
  | _ -> None

type invariant_key =
  | Inv_no_live_turn_clears_state
  | Inv_idle_requires_not_live
  | Inv_gate_rejected_requires_finalizing
  | Inv_selecting_requires_tool_policy
  | Inv_executing_requires_trying
  | Inv_compacting_requires_trying
  | Inv_terminal_cascade_requires_finalizing

let all_invariant_keys =
  [
    Inv_no_live_turn_clears_state;
    Inv_idle_requires_not_live;
    Inv_gate_rejected_requires_finalizing;
    Inv_selecting_requires_tool_policy;
    Inv_executing_requires_trying;
    Inv_compacting_requires_trying;
    Inv_terminal_cascade_requires_finalizing;
  ]

let invariant_key_to_string = function
  | Inv_no_live_turn_clears_state -> "NoLiveTurnClearsState"
  | Inv_idle_requires_not_live -> "IdleRequiresNotLive"
  | Inv_gate_rejected_requires_finalizing -> "GateRejectedRequiresFinalizing"
  | Inv_selecting_requires_tool_policy -> "SelectingRequiresToolPolicy"
  | Inv_executing_requires_trying -> "ExecutingRequiresTrying"
  | Inv_compacting_requires_trying -> "CompactingRequiresTrying"
  | Inv_terminal_cascade_requires_finalizing ->
      "TerminalCascadeRequiresFinalizing"

let invariant_key_of_string = function
  | "NoLiveTurnClearsState" -> Some Inv_no_live_turn_clears_state
  | "IdleRequiresNotLive" -> Some Inv_idle_requires_not_live
  | "GateRejectedRequiresFinalizing" ->
      Some Inv_gate_rejected_requires_finalizing
  | "SelectingRequiresToolPolicy" -> Some Inv_selecting_requires_tool_policy
  | "ExecutingRequiresTrying" -> Some Inv_executing_requires_trying
  | "CompactingRequiresTrying" -> Some Inv_compacting_requires_trying
  | "TerminalCascadeRequiresFinalizing" ->
      Some Inv_terminal_cascade_requires_finalizing
  | _ -> None
