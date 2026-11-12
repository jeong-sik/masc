(** HTTP routes exposing provider-run and dashboard observations.
    Cached projections use {!Server_dashboard_json_cache}. Decisions reads
    are Current through {!Server_dashboard_keeper_decisions_http}. *)

val add_routes :
  sw:Eio.Switch.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t
