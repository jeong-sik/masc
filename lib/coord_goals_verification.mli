(** Verification helpers for goal-management tool handlers. *)

val goal_policy_nodes : Goal_store.goal list -> Goal_verification.goal_policy_node list

val verification_summary_json
  :  ?latest_request:Goal_verification.goal_verification_request
  -> Goal_store.goal
  -> Goal_verification.policy_snapshot option
  -> Goal_verification.goal_verification_request option
  -> Yojson.Safe.t

val update_goal_phase
  :  Coord_types.context
  -> Goal_store.goal
  -> phase:Goal_phase.t
  -> ?note:string
  -> ?active_verification_request_id:string
  -> ?clear_active_verification_request:bool
  -> unit
  -> (Goal_store.goal, string) result

val actor_must_be_operator : Goal_phase.action -> bool

val emit_goal_event
  :  Coord_types.context
  -> goal_id:string
  -> event_type:string
  -> payload:Yojson.Safe.t
  -> unit
