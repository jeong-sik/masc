(** Model observability helpers for keeper status detail.

    Private helper for {!Keeper_status_detail}. *)

val nonempty_trimmed : string -> string option
val json_string_opt_member : Yojson.Safe.t -> string -> string option

val latest_metrics_json :
  metrics_store:Dated_jsonl.t ->
  metrics_path:string ->
  tail_bytes:int ->
  Yojson.Safe.t option

val model_observability_json :
  current_cascade_name:string ->
  runtime_blocker_fields:(string * Yojson.Safe.t) list ->
  Yojson.Safe.t option ->
  Yojson.Safe.t
