type agent_status = [ `Active | `Idle | `Unknown ]

type agent_state = {
  name : string;
  status : agent_status;
  last_action : string option;
}

type source_counts = {
  jsonl : int;
  sqlite : int;
  merged : int;
}

type world_state = {
  room_id : string;
  round : int;
  phase : string;
  agents : agent_state list;
  recent_events : Engine_event.t list;
  source_counts : source_counts;
}

val string_of_agent_status : agent_status -> string

val build :
  base_dir:string ->
  room_id:string ->
  (world_state, string) result
