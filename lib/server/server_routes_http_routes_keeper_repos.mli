(** Server_routes_http_routes_keeper_repos — HTTP routes for keeper-repository
    access control mappings.

    Provides endpoints for managing which repositories a keeper may access:
    - GET /api/v1/keepers/:id/repos — list allowed repositories for keeper
    - POST /api/v1/keepers/:id/repos — update mapping for keeper

    Only the wired routes are exposed via {!add_routes}. *)

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t
