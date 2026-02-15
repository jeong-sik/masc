type event_type =
  | Room_created
  | Room_started
  | Phase_changed
  | Turn_started
  | Turn_action_proposed
  | Turn_action_resolved
  | Turn_timeout
  | Keeper_unavailable
  | Metric_updated
  | Room_ended

type t = {
  seq : int;
  room_id : string;
  ts : string;
  event_type : event_type;
  actor_id : string option;
  payload : Yojson.Safe.t;
}

val string_of_event_type : event_type -> string

val make :
  seq:int ->
  room_id:string ->
  ts:string ->
  event_type:event_type ->
  ?actor_id:string ->
  payload:Yojson.Safe.t ->
  unit ->
  t
