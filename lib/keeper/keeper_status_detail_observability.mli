(** Model observability helpers for keeper status detail.

    Private helper for {!Keeper_status_detail}. *)

val nonempty_trimmed : string -> string option

val model_observability_json :
  current_runtime_id:string ->
  runtime_blocker_fields:(string * Yojson.Safe.t) list ->
  runtime_trust:Yojson.Safe.t ->
  Yojson.Safe.t option ->
  Yojson.Safe.t
