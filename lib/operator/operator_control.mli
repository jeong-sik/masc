include module type of Operator_pending_confirm
include module type of Operator_digest

val invalidate_snapshot_cache : unit -> unit

val snapshot_json :
  ?actor:string ->
  ?view:string ->
  ?include_messages:bool ->
  ?include_keepers:bool ->
  ?include_summary_fields:bool ->
  ?lightweight_summary:bool ->
  'a context ->
  Yojson.Safe.t

val snapshot_json_result :
  ?actor:string ->
  ?view:string ->
  ?include_messages:bool ->
  ?include_keepers:bool ->
  ?include_summary_fields:bool ->
  ?lightweight_summary:bool ->
  'a context ->
  (Yojson.Safe.t, string) result

val recent_actions_json : Workspace.config -> Yojson.Safe.t

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
