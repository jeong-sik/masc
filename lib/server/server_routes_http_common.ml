
open Server_auth

module Http = Http_server_eio
module Http_h2 = Http_server_h2
module Mcp_session = Mcp_session
module Mcp_server = Mcp_server
module Mcp_eio = Mcp_server_eio
module Room = Room
module Room_utils = Room_utils
module Tool_keeper = Tool_keeper
module Keeper_types = Keeper_types
module Keeper_alerting = Keeper_alerting
module Keeper_memory = Keeper_memory
module Keeper_execution = Keeper_execution
module Keeper_runtime = Keeper_runtime
module Ag_ui = Ag_ui
module Tool_operator = Tool_operator
module Operator_control = Operator_control
module Dashboard_execution = Dashboard_execution
module Dashboard_mission = Dashboard_mission
module Dashboard_mission_briefing = Dashboard_mission_briefing
module Build_identity = Build_identity
module Graphql_api = Graphql_api
module Tempo = Tempo
module Auth = Auth
module Board = Board
module Board_dispatch = Board_dispatch
module Task_dispatch = Task_dispatch
module Http_negotiation = Mcp_transport_protocol.Http_negotiation
module Progress = Progress
module Sse = Sse
module Safe_ops = Safe_ops
module Tool_board = Tool_board
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

let legacy_messages_endpoint_url =
  Server_mcp_transport_http.legacy_messages_endpoint_url

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

let require_runtime label = function
  | Some value -> value
  | None -> invalid_arg (label ^ " not available")

let contains_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    if idx + needle_len > haystack_len then
      false
    else if String.sub haystack idx needle_len = needle then
      true
    else
      loop (idx + 1)
  in
  needle_len > 0 && loop 0

let host_header_has_forbidden_authority_chars value =
  let has_forbidden_char =
    String.exists
      (function
        | '/' | '@' | '?' | '#' | '%' | ' ' | '\t' -> true
        | _ -> false)
      value
  in
  has_forbidden_char || contains_substring ~needle:"://" value

let parse_host_port host_header default_host default_port =
  match host_header with
  | None -> (default_host, default_port)
  | Some host_value -> (
      let trimmed = String.trim host_value in
      if trimmed = "" || host_header_has_forbidden_authority_chars trimmed then
        (default_host, default_port)
      else
        try
          let uri = Uri.of_string ("http://" ^ trimmed) in
          let host = Uri.host uri |> Option.value ~default:default_host in
          let port = Uri.port uri |> Option.value ~default:default_port in
          (host, port)
        with Eio.Cancel.Cancelled _ as e -> raise e | _ -> (default_host, default_port))

(** Utility: string prefix check *)
let starts_with ~prefix s =
  let plen = String.length prefix in
  String.length s >= plen && String.sub s 0 plen = prefix

(** Allowed origins for DNS rebinding protection.
    SSOT: [Masc_network_defaults.allowed_origins]. *)
let allowed_origins = Masc_network_defaults.allowed_origins

(** Validate Origin header for DNS rebinding protection *)
let validate_origin (request : Httpun.Request.t) =
  match Httpun.Headers.get request.headers "origin" with
  | None -> true
  | Some origin ->
      List.exists (fun prefix -> starts_with ~prefix origin) allowed_origins

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

let allow_legacy_accept = Server_mcp_transport_http.allow_legacy_accept

let classify_mcp_accept = Server_mcp_transport_http.classify_mcp_accept

let legacy_accept_warning_headers =
  Server_mcp_transport_http.legacy_accept_warning_headers

let legacy_transport_deprecation_headers =
  Server_mcp_transport_http.legacy_transport_deprecation_headers

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
                    base_path = state.Mcp_server.room_config.base_path;
                    sw;
                    clock;
                    handle_request =
                      (fun ?(profile = Server_mcp_transport_http.Full)
                           ?mcp_session_id
                           ?auth_token body_str ->
                        let profile =
                          mcp_eio_profile_of_transport_profile profile
                        in
                        Mcp_server_eio.handle_request ~clock ~sw ~profile
                          ?mcp_session_id ?auth_token state body_str);
                    clear_resource_subscriptions_for_session =
                      Mcp_server_eio.clear_resource_subscriptions_for_session;
                  }
            | None, _ -> Error "Eio switch not available"
            | _, None -> Error "Eio clock not available"));
    get_base_path =
      (fun () ->
        match current_server_state_opt () with
        | Some state -> state.Mcp_server.room_config.base_path
        | None -> Server_mcp_transport_http.default_base_path ());
    verify_mcp_auth =
      (fun ~base_path request ->
        Result.map (fun _ -> ()) (verify_mcp_auth ~base_path request));
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

let handle_get_mcp ?legacy_messages_endpoint
    ?(profile = Server_mcp_transport_http.Full) ?sse_kind request reqd =
  Server_mcp_transport_http.handle_get_mcp ~deps:(mcp_transport_http_deps ())
    ?legacy_messages_endpoint ~profile ?sse_kind request reqd

let sse_simple_handler request reqd =
  Server_mcp_transport_http.sse_simple_handler ~deps:(mcp_transport_http_deps ())
    request reqd

let handle_get_operator_mcp request reqd =
  Server_mcp_transport_http.handle_get_operator_mcp
    ~deps:(mcp_transport_http_deps ()) request reqd

let handle_post_messages request reqd =
  Server_mcp_transport_http.handle_post_messages ~deps:(mcp_transport_http_deps ())
    request reqd

let handle_post_mcp ?(profile = Server_mcp_transport_http.Full) request reqd =
  Server_mcp_transport_http.handle_post_mcp ~deps:(mcp_transport_http_deps ())
    ~profile request reqd

let handle_delete_mcp ?(profile = Server_mcp_transport_http.Full) request reqd =
  Server_mcp_transport_http.handle_delete_mcp ~deps:(mcp_transport_http_deps ())
    ~profile request reqd

let handle_ag_ui_events request reqd =
  Server_mcp_transport_http.handle_ag_ui_events ~deps:(mcp_transport_http_deps ())
    request reqd
