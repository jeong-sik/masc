(** Server_routes_http_routes_keeper_repos — HTTP routes for keeper-repository
    access control mappings.

    Provides endpoints for managing which repositories a keeper may access:
    - GET /api/v1/keeper-repos — list configured mappings
    - GET /api/v1/keeper-repos/:id — list allowed repositories for keeper
    - POST /api/v1/keeper-repos/:id — update mapping for keeper

    The endpoint deliberately avoids [/api/v1/keepers/*] so it does not shadow
    existing dashboard keeper detail/chat routes registered under that prefix.

    Only the wired routes are exposed via {!add_routes}. *)

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t
