(** Dashboard performance artifact projection. *)

val dashboard_perf_http_json : Coord.config -> Yojson.Safe.t
(** Renders the latest benchmark artifact summary and optional baseline
    comparison for the dashboard performance endpoint. *)
