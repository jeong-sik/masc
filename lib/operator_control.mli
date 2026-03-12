type 'a context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  mcp_session_id : string option;
}

val snapshot_json :
  ?actor:string ->
  ?view:string ->
  ?include_messages:bool ->
  ?include_sessions:bool ->
  ?include_keepers:bool ->
  'a context ->
  Yojson.Safe.t

val pending_confirms_json : ?actor:string -> Room.config -> Yojson.Safe.t
val pending_confirm_envelope_json : ?actor:string -> Room.config -> Yojson.Safe.t
val pending_confirm_summary_json : ?actor:string -> Room.config -> Yojson.Safe.t

val recent_actions_json : Room.config -> Yojson.Safe.t

val digest_json :
  ?actor:string ->
  ?target_type:string ->
  ?target_id:string ->
  ?include_workers:bool ->
  'a context ->
  (Yojson.Safe.t, string) result

val action_json :
  ?actor_hint:string ->
  float Eio.Time.clock_ty context ->
  Yojson.Safe.t ->
  (Yojson.Safe.t, string) result

val judgment_write_json :
  'a context -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

val judgment_latest_json :
  'a context -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

val confirm_json :
  ?actor_hint:string ->
  float Eio.Time.clock_ty context ->
  Yojson.Safe.t ->
  (Yojson.Safe.t, string) result
