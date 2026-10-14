(** Model observability helpers for keeper status detail.

    Private helper for {!Keeper_status_detail}. *)

val latest_metrics_json :
  metrics_store:Dated_jsonl.t ->
  Yojson.Safe.t option

val model_observability_json :
  current_runtime_id:string ->
  runtime_blocker_class:Keeper_status_bridge.runtime_blocker_class option ->
  runtime_trust:Yojson.Safe.t ->
  Yojson.Safe.t option ->
  Yojson.Safe.t
