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

let string_of_event_type = function
  | Room_created -> "room.created"
  | Room_started -> "room.started"
  | Phase_changed -> "phase.changed"
  | Turn_started -> "turn.started"
  | Turn_action_proposed -> "turn.action.proposed"
  | Turn_action_resolved -> "turn.action.resolved"
  | Turn_timeout -> "turn.timeout"
  | Keeper_unavailable -> "keeper.unavailable"
  | Metric_updated -> "metric.updated"
  | Room_ended -> "room.ended"

let make ~seq ~room_id ~ts ~event_type ?actor_id ~payload () =
  { seq; room_id; ts; event_type; actor_id; payload }
