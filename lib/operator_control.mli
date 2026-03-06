type 'a context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
}

val snapshot_json :
  ?actor:string ->
  ?include_messages:bool ->
  ?include_sessions:bool ->
  ?include_keepers:bool ->
  'a context ->
  Yojson.Safe.t

val action_json :
  ?actor_hint:string ->
  'a context ->
  Yojson.Safe.t ->
  (Yojson.Safe.t, string) result

val confirm_json :
  ?actor_hint:string ->
  'a context ->
  Yojson.Safe.t ->
  (Yojson.Safe.t, string) result
