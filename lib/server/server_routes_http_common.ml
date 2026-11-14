
open Server_auth

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

let mcp_protocol_versions = Server_mcp_transport_http.mcp_protocol_versions

let mcp_protocol_version_default =
  Server_mcp_transport_http.mcp_protocol_version_default

let default_base_path = Server_mcp_transport_http.default_base_path

let get_cookie_value = Server_mcp_transport_http.get_cookie_value

let current_server_state_opt () = current_server_state ()


(** Requests that enter the MCP transport surface.  [/]'s GET representation
    is the dashboard, while its POST representation is the legacy MCP endpoint;
    keep that method distinction explicit instead of using a path prefix. *)
let is_mcp_transport_request (request : Httpun.Request.t) =
  match request.meth, Http.Request.path request with
  | `POST, "/" -> true
  | _, ("/mcp" | "/mcp/managed" | "/mcp/operator" | "/mcp/play" | "/sse") -> true
  | _ -> false
;;

(** Validate an HTTP(S) Origin against the authority admitted at request entry.
    Native clients without an Origin remain valid. *)
let validate_origin ~request_authority (request : Httpun.Request.t) =
  match classify_request_origin ~request_authority request with
  | Missing_origin -> true
  | Single_origin { admission = (Same_origin | Allowed_dev_origin); _ } -> true
  | Single_origin { admission = Rejected; _ }
  | Multiple_origins
  | Malformed_origin ->
    false

let mcp_transport_http_deps () : Server_mcp_transport_http.deps =
  {
    get_origin;
    cors_headers;
    auth_token_from_request;
    is_ready =
      (fun () ->
        match current_server_state_opt () with
        | None -> false
        | Some _ -> (Server_startup_state.snapshot ()).state_ready);
    get_runtime_result =
      (fun () ->
        match current_server_state_opt () with
        | None -> Error "Server state not initialized"
        | Some state -> (
            match (state.Mcp_server.sw, state.Mcp_server.clock) with
            | Some sw, Some clock ->
                Ok
                  {
                    base_path = (Mcp_server.workspace_config state).base_path;
                    sw;
                    clock;
                    tool_allowed_in_profile =
                      Server_mcp_transport_http.tool_allowed_in_profile state;
                    handle_request =
                      (fun ?(profile = Server_mcp_transport_http.Full)
                           ?mcp_session_id
                           ?otel_mcp_protocol_version
                           ?otel_transport_context
                           ?auth_token ?internal_keeper_runtime body_str ->
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
    get_server_state = current_server_state_opt;
    (* HIGH-RISK-UNREVIEWED: the four verdicts below are passed on as they
       are; only the error is mapped to the transport's failure (#51752). *)
    verify_mcp_auth =
      (fun ~base_path request ->
        verify_mcp_auth ~base_path request
        |> Result.map_error
             Server_mcp_transport_http_types.auth_failure_of_masc_error);
    verify_mcp_observer_stream_auth =
      (fun ~base_path request ->
        verify_mcp_observer_stream_auth ~base_path request
        |> Result.map_error
             Server_mcp_transport_http_types.auth_failure_of_masc_error);
    verify_operator_mcp_auth =
      (fun ~base_path request ->
        verify_operator_mcp_auth ~base_path request
        |> Result.map_error
             Server_mcp_transport_http_types.auth_failure_of_masc_error);
    verify_seat_mcp_auth =
      (fun ~base_path request ->
        verify_seat_mcp_auth ~base_path request
        |> Result.map_error
             Server_mcp_transport_http_types.auth_failure_of_masc_error);
  }

let mcp_transport_json_headers session_id protocol_version origin =
  Server_mcp_transport_http.json_headers
    ~deps:(mcp_transport_http_deps ())
    session_id protocol_version origin

let mcp_headers = Server_mcp_transport_http.mcp_headers

let json_headers = mcp_transport_json_headers

let stop_sse_session = Server_mcp_transport_http.stop_sse_session

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
   cache ([Dashboard_cache.get_or_compute]), which submits it to the shared
   Executor_pool with the kind the route declares ({!Pool_work}). ~20 routes
   inline this pattern; ~28 dashboard GET routes still omit it and recompute
   uncached on the main HTTP domain per request. The uncached ones (e.g.
   /branches spawning `git branch`, /workspaces querying up to 1000 messages,
   /status) head-of-line-block other requests when a dashboard page fires
   many calls in parallel — a 12-way parallel probe converged every endpoint
   (incl. ms-cached ones) to ~3.4s because the uncached handlers held the
   single Eio domain.

   This combinator names the pattern so routes adopt it as a one-liner and
   the uncached migration stops being N-of-M hand-patching. [cache_key]
   stays caller-built so request params (limit, actor, ...) vary the entry. *)
let respond_cached_read ?(compress = true) ~request ~reqd ~cache_key ~ttl work =
  Server_cached_read_http.respond ~compress ~request reqd
    (Dashboard_cache.get_or_compute_payload cache_key ~ttl work)
