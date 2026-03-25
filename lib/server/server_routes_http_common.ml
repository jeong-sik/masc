
open Server_utils
open Server_auth
open Server_dashboard_http

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
module Command_plane_v2 = Command_plane_v2
module Dashboard_execution = Dashboard_execution
module Dashboard_mission = Dashboard_mission
module Dashboard_proof = Dashboard_proof
module Dashboard_mission_briefing = Dashboard_mission_briefing
module Build_identity = Build_identity
module Tool_audit = Tool_audit
module Graphql_api = Graphql_api
module Tempo = Tempo
module Auth = Auth
module Board = Board
module Board_dispatch = Board_dispatch
module Board_listener = Board_listener
module Council = Council
module Task_dispatch = Task_dispatch
module Http_negotiation = Mcp_protocol.Http_negotiation
module Progress = Progress
module Sse = Sse
module Safe_ops = Safe_ops
module Tool_mdal = Tool_mdal
module Tool_board = Tool_board
module Process_eio = Process_eio
module Mdal = Mdal
module Server_command_plane_http = Server_command_plane_http
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

(** Shared runtime access for MCP handlers.
    main_eio delegates to the shared Eio_context instead of storing another
    copy of switch/clock/net state. *)
let get_switch () = Eio_context.get_switch ()
let get_clock () = Eio_context.get_clock ()
let get_net () = Eio_context.get_net ()

let command_plane_http_deps : Server_command_plane_http.deps =
  {
    query_param;
    int_query_param;
    operator_actor_hint;
    get_session_id_any;
    auth_token_from_request;
    get_switch;
    get_clock;
    get_net;
    get_origin;
    cors_headers;
  }

let command_plane_summary_http_json ~state =
  Server_command_plane_http.command_plane_summary_http_json ~state

let command_plane_snapshot_http_json ~state =
  Server_command_plane_http.command_plane_snapshot_http_json ~state

let command_plane_topology_http_json ~state =
  Server_command_plane_http.command_plane_topology_http_json ~state

let command_plane_units_http_json ~state =
  Server_command_plane_http.command_plane_units_http_json ~state

let command_plane_operations_http_json ~state request =
  Server_command_plane_http.command_plane_operations_http_json
    ~deps:command_plane_http_deps ~state request

let command_plane_detachments_http_json ~state request =
  Server_command_plane_http.command_plane_detachments_http_json
    ~deps:command_plane_http_deps ~state request

let command_plane_detachment_status_http_json ~state request =
  Server_command_plane_http.command_plane_detachment_status_http_json
    ~deps:command_plane_http_deps ~state request

let command_plane_decisions_http_json ~state request =
  Server_command_plane_http.command_plane_decisions_http_json
    ~deps:command_plane_http_deps ~state request

let command_plane_capacity_http_json ~state =
  Server_command_plane_http.command_plane_capacity_http_json ~state

let command_plane_alerts_http_json ~state =
  Server_command_plane_http.command_plane_alerts_http_json ~state

let command_plane_traces_http_json ~state request =
  Server_command_plane_http.command_plane_traces_http_json
    ~deps:command_plane_http_deps ~state request

let command_plane_swarm_http_json ~state request =
  Server_command_plane_http.command_plane_swarm_http_json
    ~deps:command_plane_http_deps ~state request

let command_plane_orchestra_http_json ~state request =
  Server_command_plane_http.command_plane_orchestra_http_json
    ~deps:command_plane_http_deps ~state request

let command_plane_unit_define_http_json ~state request ~args =
  Server_command_plane_http.command_plane_unit_define_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_operation_start_http_json ~state request ~args =
  Server_command_plane_http.command_plane_operation_start_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_chain_summary_http_json ~state request =
  Server_command_plane_http.command_plane_chain_summary_http_json
    ~deps:command_plane_http_deps ~state request

let command_plane_chain_run_http_json ~state request run_id =
  Server_command_plane_http.command_plane_chain_run_http_json
    ~deps:command_plane_http_deps ~state request run_id

let chain_http_error_status message =
  Server_command_plane_http.chain_http_error_status message

let command_plane_chain_events_http ~request reqd =
  Server_command_plane_http.command_plane_chain_events_http
    ~deps:command_plane_http_deps ~request reqd

let command_plane_chain_events_h2 ~request h2_reqd =
  Server_command_plane_http.command_plane_chain_events_h2
    ~deps:command_plane_http_deps ~request h2_reqd

let command_plane_operation_checkpoint_http_json ~state request ~args =
  Server_command_plane_http.command_plane_operation_checkpoint_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_unit_reparent_http_json ~state request ~args =
  Server_command_plane_http.command_plane_unit_reparent_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_unit_reassign_http_json ~state request ~args =
  Server_command_plane_http.command_plane_unit_reassign_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_operation_pause_http_json ~state request ~args =
  Server_command_plane_http.command_plane_operation_pause_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_operation_resume_http_json ~state request ~args =
  Server_command_plane_http.command_plane_operation_resume_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_operation_stop_http_json ~state request ~args =
  Server_command_plane_http.command_plane_operation_stop_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_operation_finalize_http_json ~state request ~args =
  Server_command_plane_http.command_plane_operation_finalize_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_dispatch_plan_http_json ~state request ~args =
  Server_command_plane_http.command_plane_dispatch_plan_http_json ~state request
    ~args

let command_plane_dispatch_assign_http_json ~state request ~args =
  Server_command_plane_http.command_plane_dispatch_assign_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_dispatch_rebalance_http_json ~state request ~args =
  Server_command_plane_http.command_plane_dispatch_rebalance_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_dispatch_escalate_http_json ~state request ~args =
  Server_command_plane_http.command_plane_dispatch_escalate_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_dispatch_recall_http_json ~state request ~args =
  Server_command_plane_http.command_plane_dispatch_recall_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_dispatch_tick_http_json ~state request ~args =
  Server_command_plane_http.command_plane_dispatch_tick_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_policy_status_http_json ~state =
  Server_command_plane_http.command_plane_policy_status_http_json ~state

let command_plane_policy_approve_http_json ~state request ~args =
  Server_command_plane_http.command_plane_policy_approve_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_policy_deny_http_json ~state request ~args =
  Server_command_plane_http.command_plane_policy_deny_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_policy_update_http_json ~state request ~args =
  Server_command_plane_http.command_plane_policy_update_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_policy_freeze_http_json ~state request ~args =
  Server_command_plane_http.command_plane_policy_freeze_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_policy_kill_switch_http_json ~state request ~args =
  Server_command_plane_http.command_plane_policy_kill_switch_http_json
    ~deps:command_plane_http_deps ~state request ~args

let command_plane_help_http_json () =
  Server_command_plane_http.command_plane_help_http_json ()

let command_plane_error_json message =
  Server_command_plane_http.command_plane_error_json message
let parse_host_port host_header default_host default_port =
  match host_header with
  | None -> (default_host, default_port)
  | Some host_value ->
      (match String.split_on_char ':' host_value with
       | [host] -> (host, default_port)
       | host :: port_str :: _ ->
           let port = try int_of_string port_str with Failure _ -> default_port in
           (host, port)
       | _ -> (default_host, default_port))

(** Utility: string prefix check *)
let starts_with ~prefix s =
  let plen = String.length prefix in
  String.length s >= plen && String.sub s 0 plen = prefix

(** Allowed origins for DNS rebinding protection *)
let allowed_origins = [
  "http://localhost";
  "https://localhost";
  "http://127.0.0.1";
  "https://127.0.0.1";
  (* Cloudflare tunnel *)
  "https://masc.crying.pictures";
  "https://masc-dev.crying.pictures";
]

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

let mcp_transport_json_headers session_id protocol_version origin =
  Server_mcp_transport_http.json_headers
    ~deps:
      {
        get_origin = get_origin;
        cors_headers = cors_headers;
        auth_token_from_request = auth_token_from_request;
        get_server_state_opt = (fun () -> !server_state);
        get_sw = Eio_context.get_switch_opt;
        get_clock = Eio_context.get_clock_opt;
        verify_mcp_auth =
          (fun ~base_path request ->
            Result.map (fun _ -> ()) (verify_mcp_auth ~base_path request));
        verify_operator_mcp_auth =
          (fun ~base_path request ->
            Result.map (fun _ -> ())
              (verify_operator_mcp_auth ~base_path request));
      }
    session_id protocol_version origin

let mcp_headers = Server_mcp_transport_http.mcp_headers

let json_headers = mcp_transport_json_headers

let mcp_transport_http_deps : Server_mcp_transport_http.deps =
  {
    get_origin;
    cors_headers;
    auth_token_from_request;
    get_server_state_opt = (fun () -> !server_state);
    get_sw = Eio_context.get_switch_opt;
    get_clock = Eio_context.get_clock_opt;
    verify_mcp_auth =
      (fun ~base_path request ->
        Result.map (fun _ -> ()) (verify_mcp_auth ~base_path request));
    verify_operator_mcp_auth =
      (fun ~base_path request ->
        Result.map (fun _ -> ()) (verify_operator_mcp_auth ~base_path request));
  }

let check_sse_connect_guard = Server_mcp_transport_http.check_sse_connect_guard

let stop_sse_session = Server_mcp_transport_http.stop_sse_session

let close_all_sse_connections =
  Server_mcp_transport_http.close_all_sse_connections

let handle_get_mcp ?legacy_messages_endpoint ?(profile = Mcp_eio.Full) ?sse_kind request reqd =
  Server_mcp_transport_http.handle_get_mcp ~deps:mcp_transport_http_deps
    ?legacy_messages_endpoint ~profile ?sse_kind request reqd

let sse_simple_handler request reqd =
  Server_mcp_transport_http.sse_simple_handler ~deps:mcp_transport_http_deps
    request reqd

let handle_get_operator_mcp request reqd =
  Server_mcp_transport_http.handle_get_operator_mcp
    ~deps:mcp_transport_http_deps request reqd

let handle_post_messages request reqd =
  Server_mcp_transport_http.handle_post_messages ~deps:mcp_transport_http_deps
    request reqd

let handle_post_mcp ?(profile = Mcp_eio.Full) request reqd =
  Server_mcp_transport_http.handle_post_mcp ~deps:mcp_transport_http_deps
    ~profile request reqd

let handle_delete_mcp ?(profile = Mcp_eio.Full) request reqd =
  Server_mcp_transport_http.handle_delete_mcp ~deps:mcp_transport_http_deps
    ~profile request reqd

let handle_ag_ui_events request reqd =
  Server_mcp_transport_http.handle_ag_ui_events ~deps:mcp_transport_http_deps
    request reqd
