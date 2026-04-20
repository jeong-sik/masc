(** Server_routes_http_routes_room — Read-only HTTP routes for
    project/room state.

    Registers [GET /api/v1/status], [/tasks], [/agents],
    [/messages]. All routes require read authentication via
    {!Server_auth.with_read_auth}. *)

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t
