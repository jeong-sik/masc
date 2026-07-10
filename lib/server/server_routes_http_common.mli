(** Server_routes_http_common — HTTP routing prelude
    consumed by every routes module via
    [open Server_routes_http_common] +
    runtime-include through {!Server_routes_http}.

    External surface: 36 module aliases + 32 helpers.

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
    (e.g. [Mcp_eio.create_state] in
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
module Mcp_session = Mcp_session
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
module Task_dispatch = Task.Dispatch
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
val remember_protocol_version :
  ?otel_transport_context:Otel_dispatch_hook.transport_context ->
  string ->
  string ->
  unit

val remember_protocol_version_if_initialize_succeeded :
  ?otel_transport_context:Otel_dispatch_hook.transport_context ->
  string ->
  request_body:string ->
  response_json:Yojson.Safe.t ->
  unit

val remember_mcp_profile :
  ?otel_transport_context:Otel_dispatch_hook.transport_context ->
  string ->
  Server_mcp_transport_http.tool_profile ->
  unit
val forget_mcp_session : string -> unit
val validate_mcp_session_profile :
  profile:Server_mcp_transport_http.tool_profile ->
  string ->
  (unit, string) result
val validate_mcp_session_delete_profile :
  profile:Server_mcp_transport_http.tool_profile ->
  string ->
  (unit, string) result
val protocol_version_from_body : string -> string option

(** {1 Request introspection} *)

val get_session_id_query : string -> string option
val get_header_any_case :
  Httpun.Headers.t -> string -> string option
val get_cookie_value :
  Httpun.Request.t -> string -> string option
val get_session_id_any : Httpun.Request.t -> string option
val get_protocol_version : Httpun.Request.t -> string
val get_protocol_version_for_session :
  ?session_id:string -> Httpun.Request.t -> string

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

val allowed_origins : string list
(** Compatibility projection of {!Masc_network_defaults.allowed_origins}; not
    an authorization predicate. *)

val is_mcp_like_path : string -> bool
(** Shared MCP HTTP surface predicate used by both H1 and H2 before Origin and
    protocol admission. *)

val validate_origin : Httpun.Request.t -> bool
(** Accepts requests without [Origin] (non-browser clients) and otherwise
    delegates exact host/port admission to {!Server_auth.public_read_cors_origin_opt}.
    Prefix matching is deliberately forbidden. *)

val accepts_sse : Httpun.Request.t -> bool
val accepts_streamable_mcp : Httpun.Request.t -> bool
val request_force_json_response : Httpun.Request.t -> bool
val classify_mcp_accept :
  Httpun.Request.t ->
  Mcp_transport_protocol.Http_negotiation.accept_mode
val force_json_response : bool
val get_last_event_id : Httpun.Request.t -> int option

(** {1 Header builders} *)

val mcp_headers : string -> string -> (string * string) list
val mcp_transport_json_headers :
  string -> string -> string -> (string * string) list
val json_headers : string -> string -> string -> (string * string) list

(** {1 SSE session control} *)

val check_sse_connect_guard :
  string -> (unit, Sse_reject_reason.t * float) result
val stop_sse_session : string -> unit
val close_all_sse_connections : unit -> unit

(** {1 MCP HTTP route handlers} *)

val handle_get_mcp :
  ?profile:Server_mcp_transport_http.tool_profile ->
  ?sse_kind:Sse.session_kind ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  unit

val handle_get_operator_mcp :
  Httpun.Request.t -> Httpun.Reqd.t -> unit

val handle_post_mcp :
  ?profile:Server_mcp_transport_http.tool_profile ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  unit

val handle_delete_mcp :
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
val host_header_has_forbidden_authority_chars :
  string -> bool
val parse_host_port :
  string option -> string -> int -> string * int

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
