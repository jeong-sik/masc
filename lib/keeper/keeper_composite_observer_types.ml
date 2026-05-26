(** Keeper_composite_observer_types — type aliases, record definitions,
    and serialization functions extracted from [Keeper_composite_observer] (757 LoC).
    @since Keeper 500-line decomposition *)

type turn_phase = Keeper_registry.turn_phase =
  | Turn_idle
  | Turn_prompting
  | Turn_routing
  | Turn_executing
  | Turn_compacting
  | Turn_finalizing
  | Turn_exhausted

let all_turn_phases : Keeper_registry.packed_turn_phase list =
  [ Keeper_registry.Packed Turn_idle
  ; Keeper_registry.Packed Turn_prompting
  ; Keeper_registry.Packed Turn_routing
  ; Keeper_registry.Packed Turn_executing
  ; Keeper_registry.Packed Turn_compacting
  ; Keeper_registry.Packed Turn_finalizing
  ; Keeper_registry.Packed Turn_exhausted
  ]

type decision_stage = Keeper_registry.decision_stage =
  | Decision_undecided
  | Decision_guard_ok
  | Decision_gate_rejected
  | Decision_tool_policy_selected

let all_decision_stages : Keeper_registry.packed_decision_stage list =
  [ Keeper_registry.Packed Decision_undecided
  ; Keeper_registry.Packed Decision_guard_ok
  ; Keeper_registry.Packed Decision_gate_rejected
  ; Keeper_registry.Packed Decision_tool_policy_selected
  ]

type cascade_state = Keeper_registry.cascade_state =
  | Cascade_idle
  | Cascade_selecting
  | Cascade_trying
  | Cascade_done
  | Cascade_exhausted

let all_cascade_states : Keeper_registry.packed_cascade_state list =
  [ Keeper_registry.Packed Cascade_idle
  ; Keeper_registry.Packed Cascade_selecting
  ; Keeper_registry.Packed Cascade_trying
  ; Keeper_registry.Packed Cascade_done
  ; Keeper_registry.Packed Cascade_exhausted
  ]

type compaction_stage = Keeper_registry.compaction_stage =
  | Compaction_accumulating
  | Compaction_compacting
  | Compaction_done

let all_compaction_stages : Keeper_registry.packed_compaction_stage list =
  [ Keeper_registry.Packed Compaction_accumulating
  ; Keeper_registry.Packed Compaction_compacting
  ; Keeper_registry.Packed Compaction_done
  ]

type tla_action =
  | Action_start_turn
  | Action_measurement_broadcast
  | Action_decide_guard
  | Action_select_tool_policy
  | Action_start_cascade_selection
  | Action_select_cascade
  | Action_gate_rejected
  | Action_cascade_done
  | Action_cascade_exhausted
  | Action_finish_turn
  | Action_start_compaction
  | Action_finish_compaction
  | Action_enter_failing
  | Action_clear_failing
  | Action_enter_overflowed
  | Action_overflowed_auto_compact

let all_tla_actions =
  [
    Action_start_turn; Action_measurement_broadcast; Action_decide_guard; Action_select_tool_policy;
    Action_start_cascade_selection; Action_select_cascade; Action_gate_rejected; Action_cascade_done;
    Action_cascade_exhausted; Action_finish_turn; Action_start_compaction; Action_finish_compaction;
    Action_enter_failing; Action_clear_failing; Action_enter_overflowed; Action_overflowed_auto_compact;
  ]

type invariant_key =
  | Invariant_phase_turn_alignment
  | Invariant_no_cascade_before_measurement
  | Invariant_compaction_atomicity
  | Invariant_event_priority_monotone
  | Invariant_phase_derivation_agreement

let all_invariant_keys =
  [
    Invariant_phase_turn_alignment; Invariant_no_cascade_before_measurement;
    Invariant_compaction_atomicity; Invariant_event_priority_monotone;
    Invariant_phase_derivation_agreement;
  ]

type invariants_check = {
  phase_turn_alignment : bool;
  no_cascade_before_measurement : bool;
  compaction_atomicity : bool;
  event_priority_monotone : bool;
  phase_derivation_agreement : bool;
}

type last_outcome = {
  turn_id : int;
  ended_at : float;
  decision_stage : Keeper_registry.packed_decision_stage;
  cascade_state : Keeper_registry.packed_cascade_state;
  selected_model : string option;
}

type live_turn = {
  turn_id : int;
  started_at : float;
  last_progress_at : float;
  last_progress_kind : string option;
}

type fsm_guard_violation_bucket = {
  action : string;
  stage : string;
  count : int;
}

type snapshot = {
  keeper_name : string;
  correlation_id : string;
  run_id : string;
  ts : float;
  phase : Keeper_state_machine.phase;
  ktc_turn_phase : Keeper_registry.packed_turn_phase;
  kdp_decision : Keeper_registry.packed_decision_stage;
  kcl_cascade_state : Keeper_registry.packed_cascade_state;
  kmc_compaction : Keeper_registry.packed_compaction_stage;
  kcb_state : Keeper_failure_circuit_breaker.display_state;
  shared_measurement : Keeper_state_machine.auto_rule_summary option;
  invariants : invariants_check;
  conditions : Keeper_state_machine.conditions;
  is_live : bool;
  live_turn : live_turn option;
  last_outcome : last_outcome option;
  fiber_stop_flag : bool;
  fiber_wakeup_flag : bool;
  consecutive_noop_count : int;
  idle_seconds : int;
  last_turn_ts : float;
  fsm_guard_violations : int;
  fsm_guard_violation_breakdown : fsm_guard_violation_bucket list;
}

let turn_phase_to_string (tp : Keeper_registry.packed_turn_phase) =
  match tp with
  | Keeper_registry.Packed Turn_idle -> "idle"
  | Keeper_registry.Packed Turn_prompting -> "prompting"
  | Keeper_registry.Packed Turn_routing -> "routing"
  | Keeper_registry.Packed Turn_executing -> "executing"
  | Keeper_registry.Packed Turn_compacting -> "compacting"
  | Keeper_registry.Packed Turn_finalizing -> "finalizing"
  | Keeper_registry.Packed Turn_exhausted -> "exhausted"

let turn_phase_of_string = function
  | "idle" -> Some Turn_idle
  | "prompting" -> Some Turn_prompting
  | "routing" -> Some Turn_routing
  | "executing" -> Some Turn_executing
  | "compacting" -> Some Turn_compacting
  | "finalizing" -> Some Turn_finalizing
  | "exhausted" -> Some Turn_exhausted
  | _ -> None

let decision_stage_to_string (s : Keeper_registry.packed_decision_stage) =
  match s with
  | Keeper_registry.Packed Decision_undecided -> "undecided"
  | Keeper_registry.Packed Decision_guard_ok -> "guard_ok"
  | Keeper_registry.Packed Decision_gate_rejected -> "gate_rejected"
  | Keeper_registry.Packed Decision_tool_policy_selected -> "tool_policy_selected"

let decision_stage_of_string = function
  | "undecided" -> Some Decision_undecided
  | "guard_ok" -> Some Decision_guard_ok
  | "gate_rejected" -> Some Decision_gate_rejected
  | "tool_policy_selected" -> Some Decision_tool_policy_selected
  | _ -> None

let cascade_state_to_string (s : Keeper_registry.packed_cascade_state) =
  match s with
  | Keeper_registry.Packed Cascade_idle -> "idle"
  | Keeper_registry.Packed Cascade_selecting -> "selecting"
  | Keeper_registry.Packed Cascade_trying -> "trying"
  | Keeper_registry.Packed Cascade_done -> "done"
  | Keeper_registry.Packed Cascade_exhausted -> "exhausted"

let cascade_state_of_string = function
  | "idle" -> Some Cascade_idle
  | "selecting" -> Some Cascade_selecting
  | "trying" -> Some Cascade_trying
  | "done" -> Some Cascade_done
  | "exhausted" -> Some Cascade_exhausted
  | _ -> None

let compaction_stage_to_string (s : Keeper_registry.packed_compaction_stage) =
  match s with
  | Keeper_registry.Packed Compaction_accumulating -> "accumulating"
  | Keeper_registry.Packed Compaction_compacting -> "compacting"
  | Keeper_registry.Packed Compaction_done -> "done"

let compaction_stage_of_string = function
  | "accumulating" -> Some Compaction_accumulating
  | "compacting" -> Some Compaction_compacting
  | "done" -> Some Compaction_done
  | _ -> None

let tla_action_to_string = function
  | Action_start_turn -> "StartTurn"
  | Action_measurement_broadcast -> "MeasurementBroadcast"
  | Action_decide_guard -> "DecideGuard"
  | Action_select_tool_policy -> "SelectToolPolicy"
  | Action_start_cascade_selection -> "StartCascadeSelection"
  | Action_select_cascade -> "SelectCascade"
  | Action_gate_rejected -> "GateRejected"
  | Action_cascade_done -> "CascadeDone"
  | Action_cascade_exhausted -> "CascadeExhausted"
  | Action_finish_turn -> "FinishTurn"
  | Action_start_compaction -> "StartCompaction"
  | Action_finish_compaction -> "FinishCompaction"
  | Action_enter_failing -> "EnterFailing"
  | Action_clear_failing -> "ClearFailing"
  | Action_enter_overflowed -> "EnterOverflowed"
  | Action_overflowed_auto_compact -> "OverflowedAutoCompact"

let tla_action_of_string = function
  | "StartTurn" -> Some Action_start_turn
  | "MeasurementBroadcast" -> Some Action_measurement_broadcast
  | "DecideGuard" -> Some Action_decide_guard
  | "SelectToolPolicy" -> Some Action_select_tool_policy
  | "StartCascadeSelection" -> Some Action_start_cascade_selection
  | "SelectCascade" -> Some Action_select_cascade
  | "GateRejected" -> Some Action_gate_rejected
  | "CascadeDone" -> Some Action_cascade_done
  | "CascadeExhausted" -> Some Action_cascade_exhausted
  | "FinishTurn" -> Some Action_finish_turn
  | "StartCompaction" -> Some Action_start_compaction
  | "FinishCompaction" -> Some Action_finish_compaction
  | "EnterFailing" -> Some Action_enter_failing
  | "ClearFailing" -> Some Action_clear_failing
  | "EnterOverflowed" -> Some Action_enter_overflowed
  | "OverflowedAutoCompact" -> Some Action_overflowed_auto_compact
  | _ -> None

let invariant_key_to_string = function
  | Invariant_phase_turn_alignment -> "PhaseTurnAlignment"
  | Invariant_no_cascade_before_measurement -> "NoCascadeBeforeMeasurement"
  | Invariant_compaction_atomicity -> "CompactionAtomicity"
  | Invariant_event_priority_monotone -> "EventPriorityMonotone"
  | Invariant_phase_derivation_agreement -> "PhaseDerivationAgreement"

let invariant_key_of_string = function
  | "PhaseTurnAlignment" -> Some Invariant_phase_turn_alignment
  | "NoCascadeBeforeMeasurement" -> Some Invariant_no_cascade_before_measurement
  | "CompactionAtomicity" -> Some Invariant_compaction_atomicity
  | "EventPriorityMonotone" -> Some Invariant_event_priority_monotone
  | "PhaseDerivationAgreement" -> Some Invariant_phase_derivation_agreement
  | _ -> None
