(** Server_routes_http_common — HTTP routing prelude
    consumed by every routes module via
    [open Server_routes_http_common] +
    runtime-include through {!Server_routes_http}.

    External surface: 35 module aliases + 32 helpers.

    Runtime chain (cycle 224 indirect runtime pattern):
    Server_routes_http_common
      ↓ include Server_routes_http_common (in
        Server_routes_http)
      ↓ open Server_routes_http (in 4 indirect
        consumers: server_h2_gateway,
        server_h2_gateway_routes_extra,
        server_runtime_bootstrap, bin/main_eio)

    The module aliases at the top of the .ml are reached
    unqualified by the indirect consumers
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
module Http_h2 = Http_server_h2
module Mcp_server = Mcp_server
module Mcp_eio = Mcp_server_eio
module Workspace = Workspace
module Workspace_utils = Workspace_utils
module Keeper_tool_surface = Keeper_tool_surface
module Keeper_types = Keeper_types
module Keeper_alerting = Keeper_alerting
module Keeper_memory = Keeper_memory
module Keeper_execution = Keeper_execution
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
module Http_negotiation = Mcp_transport_protocol.Http_negotiation
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
val is_valid_protocol_version : string -> bool

(** {1 Server state} *)

val current_server_state_opt :
  unit -> Mcp_server.server_state option

val state_switch_opt :
  Mcp_server.server_state option -> Eio.Switch.t option

val state_clock_opt :
  Mcp_server.server_state option ->
  float Eio.Time.clock_ty Eio.Resource.t option

val state_net_opt :
  Mcp_server.server_state option ->
  Eio_context.eio_net option

(** {1 Origin / Accept negotiation} *)

val is_mcp_transport_request : Httpun.Request.t -> bool
(** [true] only for requests entering the MCP HTTP/SSE surface. *)

val validate_origin :
  request_authority:Server_request_authority.authority ->
  Httpun.Request.t -> bool
(** Validate a browser Origin against the authority admitted at request entry.
    Requests without Origin are native clients and remain valid. *)

val accepts_sse : Httpun.Request.t -> bool
val accepts_streamable_mcp : Httpun.Request.t -> bool
val request_force_json_response : Httpun.Request.t -> bool
val force_json_response : bool
(** {1 Header builders} *)

val mcp_headers : string -> (string * string) list
val mcp_transport_json_headers :
  string -> string -> (string * string) list
val json_headers : string -> string -> (string * string) list

(** {1 SSE session control} *)

val check_sse_connect_guard :
  string -> (unit, Sse_reject_reason.t * float) result
val stop_sse_session : string -> unit
val close_all_sse_connections : unit -> unit

(** {1 MCP HTTP route handlers} *)

val handle_get_events :
  Httpun.Request.t -> Httpun.Reqd.t -> unit

val handle_post_mcp :
  ?profile:Server_mcp_transport_http.tool_profile ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  unit

val handle_ag_ui_events :
  Httpun.Request.t -> Httpun.Reqd.t -> unit

val handle_presence_events :
  Httpun.Request.t -> Httpun.Reqd.t -> unit

(** {1 Misc helpers} *)

val mcp_transport_http_deps :
  unit -> Server_mcp_transport_http.deps
(** [respond_cached_read ~request ~reqd ~cache_key ~ttl compute] wraps a
    dashboard read [compute] in the SWR cache and the shared Executor_pool,
    then writes the JSON response. Collapses parallel read bursts to one
    compute per [ttl] and runs heavy compute (subprocess / store query /
    large JSON) off the main HTTP domain so it does not head-of-line-block
    other requests. [compress] defaults to [true]. *)
val respond_cached_read :
  ?compress:bool ->
  request:Httpun.Request.t ->
  reqd:Httpun.Reqd.t ->
  cache_key:string ->
  ttl:float ->
  (unit -> Yojson.Safe.t) ->
  unit
