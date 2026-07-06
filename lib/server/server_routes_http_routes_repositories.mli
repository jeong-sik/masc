(** Server_routes_http_routes_repositories — HTTP routes for repository
    CRUD and sync operations.

    Routes:
    - GET    /api/v1/repositories        — list all repositories
    - POST   /api/v1/repositories        — add a new repository
    - GET    /api/v1/repositories/:id    — get a single repository
    - DELETE /api/v1/repositories/:id    — remove a repository
    - POST   /api/v1/repositories/:id/sync — trigger sync for a repository

    The repository JSON projection is shared so adjacent read-only dashboard
    surfaces cannot drift from the public repository API shape. *)

val repository_json :
  base_path:string -> Repo_manager_types.repository -> Yojson.Safe.t

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t
