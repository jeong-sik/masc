
open Server_auth

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

let mcp_protocol_versions = Server_mcp_transport_http.mcp_protocol_versions

let mcp_protocol_version_default =
  Server_mcp_transport_http.mcp_protocol_version_default

let default_base_path = Server_mcp_transport_http.default_base_path

let is_valid_protocol_version =
  Server_mcp_transport_http.is_valid_protocol_version

let remember_protocol_version =
  Server_mcp_transport_http.remember_protocol_version

let remember_protocol_version_if_initialize_succeeded =
  Server_mcp_transport_http.remember_protocol_version_if_initialize_succeeded

let remember_mcp_profile = Server_mcp_transport_http.remember_mcp_profile

let forget_mcp_session = Server_mcp_transport_http.forget_mcp_session

let validate_mcp_session_profile =
  Server_mcp_transport_http.validate_mcp_session_profile

let validate_mcp_session_delete_profile =
  Server_mcp_transport_http.validate_mcp_session_delete_profile

let protocol_version_from_body =
  Server_mcp_transport_http.protocol_version_from_body

let get_session_id_query = Server_mcp_transport_http.get_session_id_query

let get_header_any_case = Server_mcp_transport_http.get_header_any_case

let get_cookie_value = Server_mcp_transport_http.get_cookie_value

let get_session_id_any = Server_mcp_transport_http.get_session_id_any

let get_protocol_version = Server_mcp_transport_http.get_protocol_version

let get_protocol_version_for_session =
  Server_mcp_transport_http.get_protocol_version_for_session

(** Prefer runtime capabilities captured in [server_state] and only fall back to
    the legacy global Eio context for compatibility with older test helpers. *)
let current_server_state_opt () = !server_state

let state_switch_opt = function
  | Some state -> (
      match state.Mcp_server.sw with
      | Some sw -> Some sw
      | None -> Eio_context.get_switch_opt ())
  | None -> Eio_context.get_switch_opt ()

let state_clock_opt = function
  | Some state -> (
      match state.Mcp_server.clock with
      | Some clock -> Some clock
      | None -> Eio_context.get_clock_opt ())
  | None -> Eio_context.get_clock_opt ()

let state_net_opt = function
  | Some state -> (
      match state.Mcp_server.net with
      | Some net -> Some net
      | None -> Eio_context.get_net_opt ())
  | None -> Eio_context.get_net_opt ()


(** Requests that enter the MCP transport surface.  [/]'s GET representation
    is the dashboard, while its POST representation is the legacy MCP endpoint;
    keep that method distinction explicit instead of using a path prefix. *)
let is_mcp_transport_request (request : Httpun.Request.t) =
  match request.meth, Http.Request.path request with
  | `POST, "/" -> true
  | _, ("/mcp" | "/mcp/managed" | "/mcp/operator" | "/sse") -> true
  | _ -> false
;;

(** Validate an HTTP(S) Origin against the authority admitted at request entry.
    Native clients without an Origin remain valid. *)
let validate_origin ~request_authority (request : Httpun.Request.t) =
  match Httpun.Headers.get request.headers "origin" with
  | None -> true
  | Some origin ->
    browser_origin_matches_request_authority ~request_authority origin

(** Check if client accepts SSE *)
let accepts_sse (request : Httpun.Request.t) =
  Http_negotiation.accepts_sse_header
    (Httpun.Headers.get request.headers "accept")

(** Check if client accepts MCP Streamable HTTP (JSON + SSE) *)
let accepts_streamable_mcp (request : Httpun.Request.t) =
  Http_negotiation.accepts_streamable_mcp
    (Httpun.Headers.get request.headers "accept")

let request_force_json_response =
  Server_mcp_transport_http.request_force_json_response

let classify_mcp_accept = Server_mcp_transport_http.classify_mcp_accept

let force_json_response = Server_mcp_transport_http.force_json_response

let get_last_event_id = Server_mcp_transport_http.get_last_event_id

let mcp_transport_http_deps () : Server_mcp_transport_http.deps =
  let mcp_eio_profile_of_transport_profile = function
    | Server_mcp_transport_http.Full -> Mcp_server_eio.Full
    | Server_mcp_transport_http.Managed_agent -> Mcp_server_eio.Managed_agent
    | Server_mcp_transport_http.Operator_remote ->
        Mcp_server_eio.Operator_remote
  in
  {
    get_origin;
    cors_headers;
    auth_token_from_request;
    is_ready = (fun () -> Option.is_some (current_server_state_opt ()));
    get_runtime_result =
      (fun () ->
        match current_server_state_opt () with
        | None -> Error "Server state not initialized"
        | Some state -> (
            match (state_switch_opt (Some state), state_clock_opt (Some state)) with
            | Some sw, Some clock ->
                Ok
                  {
                    base_path = (Mcp_server.workspace_config state).base_path;
                    sw;
                    clock;
                    handle_request =
                      (fun ?(profile = Server_mcp_transport_http.Full)
                           ?mcp_session_id
                           ?otel_mcp_protocol_version
                           ?otel_transport_context
                           ?auth_token ?internal_keeper_runtime body_str ->
                        let profile =
                          mcp_eio_profile_of_transport_profile profile
                        in
                        Mcp_server_eio.handle_request ~clock ~sw ~profile
                          ?mcp_session_id ?otel_mcp_protocol_version
                          ?otel_transport_context ?auth_token
                          ?internal_keeper_runtime state body_str);
                    clear_resource_subscriptions_for_session =
                      Mcp_server_eio.clear_resource_subscriptions_for_session;
                  }
            | None, _ -> Error "Eio switch not available"
            | _, None -> Error "Eio clock not available"));
    get_base_path =
      (fun () ->
        match current_server_state_opt () with
        | Some state -> (Mcp_server.workspace_config state).base_path
        | None -> Server_mcp_transport_http.default_base_path ());
    verify_mcp_auth =
      (fun ~base_path request ->
        Result.map (fun _ -> ()) (verify_mcp_auth ~base_path request));
    verify_mcp_observer_stream_auth =
      (fun ~base_path request ->
        Result.map (fun _ -> ()) (verify_mcp_observer_stream_auth ~base_path request));
    verify_operator_mcp_auth =
      (fun ~base_path request ->
        Result.map (fun _ -> ()) (verify_operator_mcp_auth ~base_path request));
  }

let mcp_transport_json_headers session_id protocol_version origin =
  Server_mcp_transport_http.json_headers
    ~deps:(mcp_transport_http_deps ())
    session_id protocol_version origin

let mcp_headers = Server_mcp_transport_http.mcp_headers

let json_headers = mcp_transport_json_headers

let check_sse_connect_guard = Server_mcp_transport_http.check_sse_connect_guard

let stop_sse_session = Server_mcp_transport_http.stop_sse_session

let close_all_sse_connections =
  Server_mcp_transport_http.close_all_sse_connections

let handle_get_mcp ?(profile = Server_mcp_transport_http.Full) ?sse_kind
    request reqd =
  Server_mcp_transport_http.handle_get_mcp ~deps:(mcp_transport_http_deps ())
    ~profile ?sse_kind request reqd

let handle_get_operator_mcp request reqd =
  Server_mcp_transport_http.handle_get_operator_mcp
    ~deps:(mcp_transport_http_deps ()) request reqd

let handle_post_mcp ?(profile = Server_mcp_transport_http.Full) request reqd =
  Server_mcp_transport_http.handle_post_mcp ~deps:(mcp_transport_http_deps ())
    ~profile request reqd

let handle_delete_mcp ?(profile = Server_mcp_transport_http.Full) request reqd =
  Server_mcp_transport_http.handle_delete_mcp ~deps:(mcp_transport_http_deps ())
    ~profile request reqd

let handle_ag_ui_events request reqd =
  Server_mcp_transport_http.handle_ag_ui_events ~deps:(mcp_transport_http_deps ())
    request reqd

let handle_presence_events request reqd =
  Server_mcp_transport_http.handle_presence_events
    ~deps:(mcp_transport_http_deps ()) request reqd

(* Cached + offloaded dashboard read response.

   The repeated dashboard-read pattern is: wrap a compute closure in the SWR
   cache ([Dashboard_cache.get_or_compute]) and submit it to the shared
   Executor_pool ([Domain_pool_ref.submit_io_or_inline]). ~20 routes inline
   this 2-call nesting; ~28 dashboard GET routes still omit it and recompute
   uncached on the main HTTP domain per request. The uncached ones (e.g.
   /branches spawning `git branch`, /workspaces querying up to 1000 messages,
   /status) head-of-line-block other requests when a dashboard page fires
   many calls in parallel — a 12-way parallel probe converged every endpoint
   (incl. ms-cached ones) to ~3.4s because the uncached handlers held the
   single Eio domain.

   This combinator names the pattern so routes adopt it as a one-liner and
   the uncached migration stops being N-of-M hand-patching. [cache_key]
   stays caller-built so request params (limit, actor, ...) vary the entry. *)
let respond_cached_read ?(compress = true) ~request ~reqd ~cache_key ~ttl compute =
  let json =
    Dashboard_cache.get_or_compute cache_key ~ttl (fun () ->
      Domain_pool_ref.submit_io_or_inline compute)
  in
  Http.Response.json_value ~compress ~request json reqd
