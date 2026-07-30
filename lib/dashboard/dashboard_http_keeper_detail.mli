(** Dashboard_http_keeper_detail — metrics window computation for keeper dashboard.

    Extracts the metrics series iteration loop from keepers_dashboard_json.
    Re-exports [Dashboard_http_keeper_metrics] for downstream consumers. *)

include module type of Dashboard_http_keeper_metrics

val compute_metrics_window :
  parsed_metrics:Yojson.Safe.t list ->
  compact:bool ->
  series_points:int ->
  Yojson.Safe.t list * Yojson.Safe.t * Yojson.Safe.t option
