(** Server IDE HTTP — REST endpoints for observational IDE annotations
    and code regions.

    Routes:
    - GET  /api/v1/ide/annotations
    - POST /api/v1/ide/annotations
    - DELETE /api/v1/ide/annotations/:id
    - GET  /api/v1/ide/regions

    All routes use the workspace base resolution from
    {!Server_routes_http_routes_workspace} so the IDE reads/writes
    from the correct project or keeper playground. *)

module Http = Http_server_eio

val add_routes : Http.Router.t -> Http.Router.t
