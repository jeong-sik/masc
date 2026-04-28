(** Server_routes_http_routes_attribution — HTTP routes for the
    attribution event log.

    Registers read-only routes under [/api/v1/attribution/*] for
    operator-facing event listings, gate summaries, and aggregate
    counts. Internal serialization helpers ([event_json],
    [recent_json], [gate_summary_json], [summary_json],
    [trimmed_query_param]) are intentionally hidden — the wired routes
    are the public surface. *)

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t
