(** Decision-stage FSM types and transitions. *)

type decision_stage =
  | Decision_undecided [@tla.idle]
  | Decision_guard_ok [@tla.active]
  | Decision_tool_policy_selected [@tla.active]
[@@deriving tla]

type decision_undecided
type decision_guard_ok
type decision_tool_policy_selected

type 'a decision_stage_witness =
  | Decision_undecided : decision_undecided decision_stage_witness
  | Decision_guard_ok : decision_guard_ok decision_stage_witness
  | Decision_tool_policy_selected : decision_tool_policy_selected decision_stage_witness

type packed_decision_stage = Packed : 'a decision_stage_witness -> packed_decision_stage

type decision_stage_active =
  | Decision_active_guard_ok
  | Decision_active_tool_policy_selected

val decision_stage_active_to_packed
  :  decision_stage_active
  -> packed_decision_stage
