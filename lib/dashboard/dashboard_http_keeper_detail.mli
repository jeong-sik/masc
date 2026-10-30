(** Dashboard_http_keeper_detail — metrics window computation for keeper dashboard.

    Extracts the metrics series iteration loop from keepers_dashboard_json.
    Re-exports [Dashboard_http_keeper_metrics] for downstream consumers. *)

include module type of Dashboard_http_keeper_metrics

val compute_metrics_window :
  parsed_metrics:Yojson.Safe.t list ->
  compact:bool ->
  series_points:int ->
  Yojson.Safe.t list * Yojson.Safe.t
(** [compute_metrics_window ~parsed_metrics ~compact ~series_points] returns the
    per-turn series and the window summary.

    A Turn row enters both when it carries [ts_unix], a non-empty [trace_id],
    [latency_ms], [tool_call_count], [tools_used], a decodable work kind and a
    known [channel]. Heartbeat rows raise the heartbeat counter only. With
    [compact] set the series is empty and the summary still counts every row. *)
