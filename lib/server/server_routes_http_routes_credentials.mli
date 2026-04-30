(** Server_routes_http_routes_credentials — HTTP routes for credential management.

    Provides CRUD endpoints for repository credentials:
    - GET /api/v1/credentials — list all credentials
    - GET /api/v1/credentials/:id — find credential by id
    - POST /api/v1/credentials — add new credential
    - DELETE /api/v1/credentials/:id — remove credential

    Only the wired routes are exposed via {!add_routes}. *)

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t
