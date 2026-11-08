(** Server_routes_http_common — HTTP routing prelude
    consumed by every routes module via
    [open Server_routes_http_common] +
    runtime-include through {!Server_routes_http}.

    Runtime chain (cycle 224 indirect runtime pattern):
    Server_routes_http_common
      ↓ include Server_routes_http_common (in
        Server_routes_http)
      ↓ open Server_routes_http (in
        server_runtime_bootstrap)

    The module aliases at the top of the .ml are reached
    unqualified by the indirect consumer
    (e.g. [Mcp_eio.create_state_eio] in
    [server_runtime_bootstrap], [Sse.X] across many
    modules). *)

(** {1 Module aliases — re-exports of common dependencies}

    Pinned because the routes prelude pattern threads
    these aliases unqualified to every consumer through
    the [open Server_routes_http_common] +
    [open Server_routes_http] runtime.  Without these
    aliases the consumers would have to import each
    underlying module explicitly. *)

module Http = Http_server_eio
module Mcp_session = Mcp_session
module Mcp_server = Mcp_server
module Mcp_eio = Mcp_server_eio
module Workspace = Workspace
module Workspace_utils = Workspace_utils
module Keeper_tool_surface = Keeper_tool_surface
module Keeper_types = Keeper_types
module Keeper_alerting = Keeper_alerting
module Keeper_memory = Keeper_memory
module Keeper_runtime = Keeper_runtime
module Ag_ui = Ag_ui
module Tool_operator = Tool_operator
module Operator_control = Operator_control
module Dashboard_execution = Dashboard_execution
module Dashboard_briefing = Dashboard_briefing
module Dashboard_briefing_sections = Dashboard_briefing_sections
module Build_identity = Build_identity
module Graphql_api = Graphql_api
module Tempo = Tempo
module Auth = Auth
module Board = Board
module Board_dispatch = Board_dispatch
module Progress = Progress
module Sse = Sse
module Safe_ops = Safe_ops
module Board_tool = Board_tool
module Process_eio = Process_eio
module Server_mcp_transport_http = Server_mcp_transport_http

(** {1 Protocol version + session profile} *)

val mcp_protocol_versions : string list
val mcp_protocol_version_default : string
val default_base_path : unit -> string

(** {1 Request introspection} *)

val get_cookie_value :
  Httpun.Request.t -> string -> string option

(** {1 Server state} *)

val current_server_state_opt :
  unit -> Mcp_server.server_state option

(** {1 Origin} *)

val is_mcp_transport_request : Httpun.Request.t -> bool
(** [true] only for requests entering the MCP HTTP/SSE surface. *)

val validate_origin :
  request_authority:Server_request_authority.authority ->
  Httpun.Request.t -> bool
(** Validate a browser Origin against the authority admitted at request entry.
    Requests without Origin are native clients and remain valid. *)

(** {1 Header builders} *)

val mcp_headers : string -> string -> (string * string) list
val json_headers : string -> string -> string -> (string * string) list

(** {1 SSE session control} *)

val stop_sse_session : string -> unit

(** {1 MCP HTTP route handlers} *)

val handle_get_mcp :
  ?profile:Server_mcp_transport_http.tool_profile ->
  ?sse_kind:Sse.session_kind ->
  Httpun.Request.t ->
  Http_reqd.t ->
  unit

val handle_get_operator_mcp :
  Httpun.Request.t -> Http_reqd.t -> unit

val handle_post_mcp :
  ?profile:Server_mcp_transport_http.tool_profile ->
  Httpun.Request.t ->
  Http_reqd.t ->
  unit

val handle_delete_mcp :
  ?profile:Server_mcp_transport_http.tool_profile ->
  Httpun.Request.t ->
  Http_reqd.t ->
  unit

val handle_ag_ui_events :
  Httpun.Request.t -> Http_reqd.t -> unit

val handle_presence_events :
  Httpun.Request.t -> Http_reqd.t -> unit

(** {1 Misc helpers} *)

val mcp_transport_http_deps :
  unit -> Server_mcp_transport_http.deps
(** [respond_cached_read ~request ~reqd ~cache_key ~ttl work] wraps a
    dashboard read [work] in the SWR cache and the shared Executor_pool, which
    runs it with the kind it declares, then writes the JSON response.
    Collapses parallel read bursts to one compute per [ttl] and runs heavy
    compute (subprocess / store query / large JSON) off the main HTTP domain
    so it does not head-of-line-block
    other requests. The response is {!Server_cached_read_http.respond}: the
    bytes the cache serialized with the entry, and 504 for a timeout
    envelope. [compress] defaults to [true]. *)
val respond_cached_read :
  ?compress:bool ->
  request:Httpun.Request.t ->
  reqd:Http_reqd.t ->
  cache_key:string ->
  ttl:float ->
  Yojson.Safe.t Pool_work.t ->
  unit
