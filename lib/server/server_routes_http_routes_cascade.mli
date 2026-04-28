(** Server_routes_http_routes_cascade — HTTP routes for cascade
    history, config, and provider mapping.

    Internal helpers ([clamp_history_limit], [parse_history_kind],
    [parse_history_since], [config_source_text_of_body]) are hidden
    — only the wired routes are exposed via {!add_routes}. *)

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t
