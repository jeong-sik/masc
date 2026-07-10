(** Goal phase health, FSM, and disposition projections. *)

open Dashboard_goals_types_accessor

val goal_phase_to_health : Goal_phase.t -> string option

val goal_health_reason :
  goal_phase:Goal_phase.t ->
  blocked_by_receipt:bool ->
  child_blocked:bool ->
  pending_approvals:int ->
  sandbox_risk:bool ->
  runtime_risk:bool ->
  verification_pending:bool ->
  stalled:bool ->
  stagnation_seconds:int ->
  child_at_risk:bool ->
  linkage_warning_reason:string option ->
  activity_observation:string ->
  stagnation_status:string ->
  string

val tree_health :
  goal_phase:Goal_phase.t ->
  blocked_by_receipt:bool ->
  child_blocked:bool ->
  at_risk:bool ->
  string

val tree_badges :
  pending_approvals:int ->
  sandbox_risk:bool ->
  runtime_risk:bool ->
  verification_pending:bool ->
  stalled:bool ->
  activity_unobserved:bool ->
  string list

val approval_matches_goal : string -> Yojson.Safe.t -> bool

val keeper_name_matches_meta : Keeper_meta_contract.keeper_meta list -> string -> bool

val keeper_name_of_assignee :
  Keeper_meta_contract.keeper_meta list -> string -> string option

val goal_fsm_state_kind : Goal_phase.t -> string

val goal_fsm_next_actions :
  goal_phase:Goal_phase.t ->
  has_effective_verifier_policy:bool ->
  require_completion_approval:bool ->
  string list

val goal_fsm_to_json :
  effective_policy:'a option ->
  Goal_store.goal ->
  tree_node ->
  Yojson.Safe.t

val display_disposition_of_receipt_json :
  Yojson.Safe.t -> string * string * string * string
