(** Keeper_registry_types_decision — decision_stage FSM types and transitions.

    Extracted from [Keeper_registry_types] (658 LoC). Pure type definitions
    and functions for the decision_stage GADT, witnesses, and transition matrix.

    @since Keeper 500-line decomposition *)

type decision_stage =
  | Decision_undecided [@tla.idle]
  | Decision_guard_ok [@tla.active]
  | Decision_tool_policy_selected [@tla.active]
[@@deriving tla]

type decision_undecided = |
type decision_guard_ok = |
type decision_tool_policy_selected = |

type 'a decision_stage_witness =
  | Decision_undecided : decision_undecided decision_stage_witness
  | Decision_guard_ok : decision_guard_ok decision_stage_witness
  | Decision_tool_policy_selected : decision_tool_policy_selected decision_stage_witness

type packed_decision_stage = Packed : 'a decision_stage_witness -> packed_decision_stage

(* Decision stages valid as ADVANCE targets within a turn.
   Excludes [Decision_undecided] (the initial state, set only by
   [mark_turn_started] / [mark_agent_core_turn_started]).  The 2 spec-forbidden
   [<active>_to_undecided] transitions are unrepresentable through this
   type, replacing the prior runtime [invalid_arg] inside
   [set_turn_decision_stage]. *)
type decision_stage_active =
  | Decision_active_guard_ok
  | Decision_active_tool_policy_selected

let decision_stage_active_to_packed : decision_stage_active -> packed_decision_stage =
  function
  | Decision_active_guard_ok -> Packed Decision_guard_ok
  | Decision_active_tool_policy_selected -> Packed Decision_tool_policy_selected
;;
