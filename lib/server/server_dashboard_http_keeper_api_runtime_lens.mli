(** Runtime-lens JSON cluster for keeper dashboard API. *)

val runtime_lens_json :
  config:Coord.config ->
  keeper_name:string ->
  trace_id:string ->
  ?turn_id:int ->
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Yojson.Safe.t
