(** Explicit Goal FSM and linkage projections. *)

open Dashboard_goals_types_accessor

val approval_matches_goal : string -> Yojson.Safe.t -> bool

val keeper_name_matches_meta : Keeper_meta_contract.keeper_meta list -> string -> bool

val keeper_name_of_assignee :
  Keeper_meta_contract.keeper_meta list -> string -> string option

val goal_fsm_state_kind : Goal_phase.t -> string

val goal_fsm_next_actions :
  goal_phase:Goal_phase.t -> string list

val goal_fsm_to_json :
  Goal_store.goal ->
  tree_node ->
  Yojson.Safe.t
