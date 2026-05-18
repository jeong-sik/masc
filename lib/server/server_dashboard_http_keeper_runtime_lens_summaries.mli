(** Runtime-lens support summaries for keeper runtime trace responses. *)

val claim_scope_summary_json :
  keeper_name:string ->
  trace_id:string ->
  ?turn_id:int ->
  unit ->
  Yojson.Safe.t

val config_drift_summary_json :
  config:Coord.config -> keeper_name:string -> Yojson.Safe.t
