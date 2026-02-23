type event_type =
  | Room_created
  | Room_started
  | Phase_changed
  | Turn_started
  | Turn_action_proposed
  | Turn_action_resolved
  | Combat_attack
  | Combat_defense
  | Turn_timeout
  | Keeper_unavailable
  | Metric_updated
  | Room_ended
  | Session_outcome
  | Dice_rolled
  | Hp_changed
  | Inventory_changed
  | Flag_set
  | Node_advanced
  | Narration_posted
  | Scene_transition
  | Quest_update
  | World_event
  | Session_started
  | Party_selected
  | Actor_spawned
  | Actor_updated
  | Actor_deleted
  | Actor_claimed
  | Actor_released
  | Join_window_opened
  | Join_window_closed
  | Mid_join_requested
  | Mid_join_granted
  | Mid_join_rejected
  | Contribution_delta
  | Memory_signal
  | Intervention_submitted
  | Intervention_applied
  | Bdi_updated
  | Evaluation_scored

type t = {
  seq : int;
  room_id : string;
  ts : string;
  event_type : event_type;
  actor_id : string option;
  payload : Yojson.Safe.t;
}

val string_of_event_type : event_type -> string
val event_type_of_string : string -> (event_type, string) result

val make :
  seq:int ->
  room_id:string ->
  ts:string ->
  event_type:event_type ->
  ?actor_id:string ->
  payload:Yojson.Safe.t ->
  unit ->
  t

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
