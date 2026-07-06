(** Dashboard_http_keeper_detail — metrics window computation for keeper dashboard.

    Extracts the metrics series iteration loop from keepers_dashboard_json.
    Re-exports [Dashboard_http_keeper_metrics] for downstream consumers. *)

include module type of Dashboard_http_keeper_metrics

val compute_metrics_window :
  ?parsed_metric_lines:Keeper_status_metrics.parsed_metrics_json_line list ->
  parsed_metrics:Yojson.Safe.t list ->
  generation:int ->
  compact:bool ->
  series_points:int ->
  metrics_window_max_bytes:int ->
  primary_model_norm:string ->
  primary_model:string ->
  Yojson.Safe.t list * Yojson.Safe.t * Yojson.Safe.t option * Yojson.Safe.t option
