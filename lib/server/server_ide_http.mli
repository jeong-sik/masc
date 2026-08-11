(** Server IDE HTTP — REST endpoints for observational IDE annotations
    and code regions.

    Routes:
    - GET  /api/v1/ide/annotations
    - POST /api/v1/ide/annotations
    - DELETE /api/v1/ide/annotations/:id
    - GET  /api/v1/ide/regions
    - GET  /api/v1/ide/events
    - GET  /api/v1/ide/presence
    - GET  /api/v1/ide/cursors
    - POST /api/v1/ide/cursors
    - GET  /api/v1/ide/memory

    All routes use the workspace base resolution from
    {!Server_routes_http_routes_workspace} so the IDE reads/writes
    from the correct project or keeper playground. *)

module Http = Http_server_eio

type public_read_response = private {
  status : [ `OK | `Bad_request ];
  body : Yojson.Safe.t;
  extra_headers : (string * string) list;
  use_public_cors : bool;
  compress : bool;
}
(** Transport-neutral result for the public IDE observation projection.

    HTTP/1 and h2c adapt this value with their own response writers so a
    missing or stale repository selection falls back to the same default
    lane on both transports. *)

val public_read_response :
  state:Mcp_server.server_state -> Httpun.Request.t -> public_read_response option
(** Resolve one public IDE read endpoint, including the observation snapshot,
    [/api/v1/agents], and [/api/v1/status].  [None] means the request is not
    owned by this route group. *)

val observation_snapshot_public_read_response :
  Httpun.Request.t -> public_read_response
(** Snapshot projection which deliberately does not require initialized server
    state.  The H1 and h2c transports use it directly during startup. *)

type public_mutation_response = private {
  status : [ `Created | `No_content | `Bad_request | `Internal_server_error ];
  body : Yojson.Safe.t option;
}
(** Transport-neutral result for an IDE observation mutation.

    Annotation and cursor writes deliberately share the public feature lane
    with reads: callers need neither a selected repository nor a bearer token.
    The h2c adapter consumes this value directly; the HTTP/1 router preserves
    the same input/output contract while using its native async body reader. *)

val public_annotation_create_response :
  state:Mcp_server.server_state
  -> request:Httpun.Request.t
  -> body:string
  -> public_mutation_response

val public_annotation_delete_response :
  state:Mcp_server.server_state
  -> request:Httpun.Request.t
  -> public_mutation_response

val public_cursor_create_response :
  state:Mcp_server.server_state
  -> request:Httpun.Request.t
  -> body:string
  -> public_mutation_response

val add_routes : Http.Router.t -> Http.Router.t
