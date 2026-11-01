(** HTTP routes exposing provider-run and dashboard observations.
    Bounded cache execution is owned by {!Server_dashboard_json_cache}. *)

val add_routes :
  sw:Eio.Switch.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t
