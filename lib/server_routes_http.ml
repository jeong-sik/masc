[@@@warning "-32-33-69"]

open Types
open Server_utils
open Server_auth
open Server_tts_proxy
open Server_trpg_rest
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
module Context_manager = Context_manager
module Llm_client = Llm_client
module Tool_perpetual = Tool_perpetual
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

(** GraphQL response headers *)
let graphql_headers origin =
  [("content-type", "application/json")]
  @ cors_headers origin

(** GraphQL Playground HTML (GET /graphql) *)
let graphql_playground_html ~nonce =
  String.concat "" [
    {|
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="user-scalable=no,initial-scale=1,minimum-scale=1,maximum-scale=1" />
    <title>MASC GraphQL Playground</title>
    <link rel="stylesheet" href="/static/css/middleware.css" />
  </head>
  <body>
    <style>
      html { font-family: "Open Sans", sans-serif; overflow: hidden; }
      body { margin: 0; background: #172a3a; }
      .playgroundIn { animation: playgroundIn .5s ease-out forwards; }
      @keyframes playgroundIn {
        from { opacity: 0; transform: translateY(10px); }
        to { opacity: 1; transform: translateY(0); }
      }
    </style>
    <style>
      .fadeOut { animation: fadeOut .5s ease-out forwards; }
      @keyframes fadeIn {
        from { opacity: 0; transform: translateY(-10px); }
        to { opacity: 1; transform: translateY(0); }
      }
      @keyframes fadeOut {
        from { opacity: 1; transform: translateY(0); }
        to { opacity: 0; transform: translateY(-10px); }
      }
      @keyframes appearIn {
        from { opacity: 0; transform: translateY(0); }
        to { opacity: 1; transform: translateY(0); }
      }
      @keyframes scaleIn {
        from { transform: scale(0); }
        to { transform: scale(1); }
      }
      @keyframes innerDrawIn {
        0% { stroke-dashoffset: 70; }
        50% { stroke-dashoffset: 140; }
        100% { stroke-dashoffset: 210; }
      }
      @keyframes outerDrawIn {
        0% { stroke-dashoffset: 76; }
        100% { stroke-dashoffset: 152; }
      }
      #loading-wrapper {
        position: absolute;
        width: 100vw;
        height: 100vh;
        display: flex;
        align-items: center;
        justify-content: center;
        flex-direction: column;
      }
      .logo {
        width: 75px;
        height: 75px;
        margin-bottom: 20px;
        opacity: 0;
        animation: fadeIn .5s ease-out forwards;
      }
      .text {
        font-size: 32px;
        font-weight: 200;
        text-align: center;
        color: rgba(255, 255, 255, .6);
        opacity: 0;
        animation: fadeIn .5s ease-out forwards;
      }
      .text strong { font-weight: 400; }
    </style>
    <div id="loading-wrapper">
      <svg class="logo" viewBox="0 0 128 128" xmlns:xlink="http://www.w3.org/1999/xlink">
        <title>GraphQL Playground Logo</title>
        <defs>
          <linearGradient id="linearGradient-1" x1="4.86%" x2="96.21%" y1="0%" y2="99.66%">
            <stop stop-color="#E00082" stop-opacity=".8" offset="0%"></stop>
            <stop stop-color="#E00082" offset="100%"></stop>
          </linearGradient>
        </defs>
        <g>
          <rect id="Gradient" width="127.96" height="127.96" y="1" fill="url(#linearGradient-1)" rx="4"></rect>
          <path id="Border" fill="#E00082" fill-rule="nonzero" d="M4.7 2.84c-1.58 0-2.86 1.28-2.86 2.85v116.57c0 1.57 1.28 2.84 2.85 2.84h116.57c1.57 0 2.84-1.26 2.84-2.83V5.67c0-1.55-1.26-2.83-2.83-2.83H4.67zM4.7 0h116.58c3.14 0 5.68 2.55 5.68 5.7v116.58c0 3.14-2.54 5.68-5.68 5.68H4.68c-3.13 0-5.68-2.54-5.68-5.68V5.68C-1 2.56 1.55 0 4.7 0z"></path>
          <path class="bglIGM" x="64" y="28" fill="#fff" d="M64 36c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8"></path>
          <path class="ksxRII" x="95.98500061035156" y="46.510000228881836" fill="#fff" d="M89.04 50.52c-2.2-3.84-.9-8.73 2.94-10.96 3.83-2.2 8.72-.9 10.95 2.94 2.2 3.84.9 8.73-2.94 10.96-3.85 2.2-8.76.9-10.97-2.94"></path>
          <path class="cWrBmb" x="95.97162628173828" y="83.4900016784668" fill="#fff" d="M102.9 87.5c-2.2 3.84-7.1 5.15-10.94 2.94-3.84-2.2-5.14-7.12-2.94-10.96 2.2-3.84 7.12-5.15 10.95-2.94 3.86 2.23 5.16 7.12 2.94 10.96"></path>
          <path class="Wnusb" x="64" y="101.97999572753906" fill="#fff" d="M64 110c-4.43 0-8-3.6-8-8.02 0-4.44 3.57-8.02 8-8.02s8 3.58 8 8.02c0 4.4-3.57 8.02-8 8.02"></path>
          <path class="bfPqf" x="32.03982162475586" y="83.4900016784668" fill="#fff" d="M25.1 87.5c-2.2-3.84-.9-8.73 2.93-10.96 3.83-2.2 8.72-.9 10.95 2.94 2.2 3.84.9 8.73-2.94 10.96-3.85 2.2-8.74.9-10.95-2.94"></path>
          <path class="edRCTN" x="32.033552169799805" y="46.510000228881836" fill="#fff" d="M38.96 50.52c-2.2 3.84-7.12 5.15-10.95 2.94-3.82-2.2-5.12-7.12-2.92-10.96 2.2-3.84 7.12-5.15 10.95-2.94 3.83 2.23 5.14 7.12 2.94 10.96"></path>
          <path class="iEGVWn" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M63.55 27.5l32.9 19-32.9-19z"></path>
          <path class="bsocdx" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M96 46v38-38z"></path>
          <path class="jAZXmP" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M96.45 84.5l-32.9 19 32.9-19z"></path>
          <path class="hSeArx" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M64.45 103.5l-32.9-19 32.9 19z"></path>
          <path class="bVgqGk" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M32 84V46v38z"></path>
          <path class="hEFqBt" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M31.55 46.5l32.9-19-32.9 19z"></path>
          <path class="dzEKCM" id="Triangle-Bottom" stroke="#fff" stroke-width="4" d="M30 84h70" stroke-linecap="round"></path>
          <path class="DYnPx" id="Triangle-Left" stroke="#fff" stroke-width="4" d="M65 26L30 87" stroke-linecap="round"></path>
          <path class="hjPEAQ" id="Triangle-Right" stroke="#fff" stroke-width="4" d="M98 87L63 26" stroke-linecap="round"></path>
        </g>
      </svg>
      <div class="text">Loading <strong>GraphQL Playground</strong></div>
    </div>
    <div id="root"></div>
    <script nonce="|};
    nonce;
    {|">
      window.addEventListener("load", function () {
        var loading = document.getElementById("loading-wrapper");
        if (loading) {
          loading.classList.add("fadeOut");
        }
        var root = document.getElementById("root");
        if (!root) {
          return;
        }
        root.classList.add("playgroundIn");
        GraphQLPlayground.init(root, {
          endpoint: "/graphql",
          settings: { "request.credentials": "same-origin" }
        });
      });
    </script>
    <script src="/static/js/middleware.js"></script>
  </body>
</html>
|};
  ]

let graphql_csp_header nonce =
  Printf.sprintf
    "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; \
     connect-src 'self'; img-src 'self' data:; \
     script-src 'self' 'nonce-%s' 'unsafe-eval'; \
     style-src 'self' 'unsafe-inline'; \
     font-src 'self' data:; \
     worker-src 'self' blob:"
    nonce

(** Resolve assets root *)
let assets_root () =
  let is_dir path =
    Sys.file_exists path && Sys.is_directory path
  in
  let exe_assets =
    let exe_dir = Filename.dirname Sys.executable_name in
    let root = Filename.dirname (Filename.dirname (Filename.dirname exe_dir)) in
    Filename.concat root "assets"
  in
  let env_assets =
    match Sys.getenv_opt "MASC_ASSETS_ROOT" with
    | Some path when String.trim path <> "" -> Some path
    | _ -> Sys.getenv_opt "MASC_ASSETS_DIR"
  in
  match env_assets with
  | Some path when is_dir path -> path
  | _ when is_dir exe_assets -> exe_assets
  | _ when is_dir (Filename.concat (Sys.getcwd ()) "assets") ->
      Filename.concat (Sys.getcwd ()) "assets"
  | _ -> Filename.concat (Sys.getcwd ()) "assets"

(** Local GraphiQL assets *)
let graphiql_asset_root () =
  Filename.concat (assets_root ()) "graphiql"

let graphiql_asset_path name =
  Filename.concat (graphiql_asset_root ()) name

let asset_content_type name =
  if Filename.check_suffix name ".css" then
    "text/css; charset=utf-8"
  else if Filename.check_suffix name ".js" then
    "application/javascript; charset=utf-8"
  else if Filename.check_suffix name ".html" then
    "text/html; charset=utf-8"
  else if Filename.check_suffix name ".svg" then
    "image/svg+xml"
  else if Filename.check_suffix name ".png" then
    "image/png"
  else if Filename.check_suffix name ".jpg" || Filename.check_suffix name ".jpeg" then
    "image/jpeg"
  else if Filename.check_suffix name ".webp" then
    "image/webp"
  else if Filename.check_suffix name ".json" then
    "application/json"
  else if Filename.check_suffix name ".woff2" then
    "font/woff2"
  else if Filename.check_suffix name ".map" then
    "application/json"
  else
    "application/octet-stream"

let read_file path =
  try Ok (In_channel.with_open_bin path In_channel.input_all)
  with exn -> Error (Printexc.to_string exn)

let serve_graphiql_asset name _request reqd =
  let path = graphiql_asset_path name in
  match read_file path with
  | Ok body ->
      Http.Response.bytes ~content_type:(asset_content_type name) body reqd
  | Error _ ->
      Http.Response.not_found reqd

(** Local GraphQL Playground assets *)
let playground_asset_root () =
  Filename.concat (assets_root ()) "playground"

let playground_asset_path name =
  Filename.concat (playground_asset_root ()) name

let serve_playground_asset name _request reqd =
  let path = playground_asset_path name in
  match read_file path with
  | Ok body ->
      Http.Response.bytes ~content_type:(asset_content_type name) body reqd
  | Error _ ->
      Http.Response.not_found reqd

(** Dashboard SPA assets (Preact + HTM, built by Vite) *)
let dashboard_asset_root () =
  Filename.concat (assets_root ()) "dashboard"

let dashboard_index_path () =
  Filename.concat (dashboard_asset_root ()) "index.html"

let dashboard_etag () =
  try
    let st = Unix.stat (dashboard_index_path ()) in
    let hash =
      Digest.string (string_of_float st.Unix.st_mtime) |> Digest.to_hex
    in
    String.sub hash 0 12
  with _ -> "none"

let dashboard_index_cache_control = "no-store, max-age=0, must-revalidate"

let serve_dashboard_index request reqd =
  match read_file (dashboard_index_path ()) with
  | Ok body ->
      Http.Response.html_cached
        ~etag:(dashboard_etag ())
        ~request body reqd
  | Error _ ->
      Http.Response.html
        "<html><body>Dashboard build not found. Run: cd dashboard &amp;&amp; npm run build</body></html>"
        reqd

let serve_dashboard_static name _request reqd =
  let path = Filename.concat (dashboard_asset_root ()) name in
  match read_file path with
  | Ok body ->
      Http.Response.bytes ~content_type:(asset_content_type name) body reqd
  | Error _ ->
      Http.Response.not_found reqd

let favicon_svg = {|
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="12" fill="#0f172a"/>
  <circle cx="32" cy="32" r="18" fill="#1d4ed8"/>
  <path d="M22 42 L32 18 L42 42 Z" fill="#93c5fd"/>
</svg>
|}

let serve_favicon _request reqd =
  Http.Response.bytes ~content_type:"image/svg+xml" favicon_svg reqd

let is_dashboard_spa_deep_link path =
  starts_with ~prefix:"/dashboard/" path
  && not (starts_with ~prefix:"/dashboard/assets/" path)
  && path <> "/dashboard/credits"
  && path <> "/dashboard/lodge"

(** CORS preflight response headers *)
let cors_preflight_headers origin =
  [
    ("access-control-allow-origin", origin);
    ("access-control-allow-methods", "GET, POST, DELETE, OPTIONS");
    ("access-control-allow-headers", cors_allow_headers_value);
    ("access-control-expose-headers", "Mcp-Session-Id, Mcp-Protocol-Version");
  ]

(** JSON-RPC error response helper *)
let json_rpc_error code message =
  Printf.sprintf
    {|{"jsonrpc":"2.0","error":{"code":%d,"message":"%s"},"id":null}|}
    code
    (String.escaped message)

let is_http_error_response = function
  | `Assoc fields ->
      let id_is_null =
        match List.assoc_opt "id" fields with
        | Some `Null -> true
        | _ -> false
      in
      let code =
        match List.assoc_opt "error" fields with
        | Some (`Assoc err_fields) ->
            (match List.assoc_opt "code" err_fields with
             | Some (`Int c) -> Some c
             | _ -> None)
        | _ -> None
      in
      id_is_null && (code = Some (-32700) || code = Some (-32600))
  | _ -> false

(** Server start time for uptime calculation *)
let server_start_time = Unix.gettimeofday ()

(** Health check handler *)
let health_handler _request reqd =
  let uptime_secs = int_of_float (Unix.gettimeofday () -. server_start_time) in
  let uptime_str =
    if uptime_secs < 60 then Printf.sprintf "%ds" uptime_secs
    else if uptime_secs < 3600 then Printf.sprintf "%dm %ds" (uptime_secs / 60) (uptime_secs mod 60)
    else Printf.sprintf "%dh %dm" (uptime_secs / 3600) ((uptime_secs mod 3600) / 60)
  in
  let build = Build_identity.current () in
  let lodge_json = Lodge_heartbeat.(lodge_status () |> lodge_status_to_json) in
  let gardener_json = Gardener.status_json () in
  let guardian_json = Guardian.status_json () in
  let sentinel_json = Sentinel.status_json () in
  let health_json = `Assoc [
    ("status", `String "ok");
    ("server", `String "masc-mcp");
    ("version", `String build.release_version);
    ("release_version", `String build.release_version);
    ("build", Build_identity.to_yojson build);
    ( "protocol",
      `Assoc
        [
          ("default", `String mcp_protocol_version_default);
          ( "supported",
            `List (List.map (fun v -> `String v) mcp_protocol_versions) );
        ] );
    ( "transport",
      `Assoc
        [
          ("streamable_http_default", `Bool true);
          ("allow_legacy_accept", `Bool allow_legacy_accept);
          ("legacy_endpoints_deprecated", `Bool true);
        ] );
    ("uptime", `String uptime_str);
    ("sse_clients", `Int (Sse.client_count ()));
    ("lodge", lodge_json);
    ("gardener", gardener_json);
    ("guardian", guardian_json);
    ("sentinel", sentinel_json);
  ] in
  Http.Response.json (Yojson.Safe.to_string health_json) reqd

let board_post_detail_json ~response_format ~post_id =
  match Board_dispatch.get_post ~post_id with
  | Error _ ->
      (`Not_found, {|{"error":"Post not found"}|})
  | Ok post ->
      let author = Board.Agent_id.to_string post.author in
      let author_karma = Board_dispatch.get_agent_karma ~agent_name:author in
      let comments =
        match Board_dispatch.get_comments ~post_id with
        | Ok cs -> cs
        | Error _ -> []
      in
      let post_json = board_post_dashboard_json ~author_karma post in
      let comments_json = `List (List.map Board.comment_to_yojson comments) in
      let json =
        if String.equal (String.lowercase_ascii (String.trim response_format)) "flat" then
          match post_json with
          | `Assoc fields -> `Assoc (fields @ [ ("comments", comments_json) ])
          | _ -> `Assoc [ ("post", post_json); ("comments", comments_json) ]
        else
          `Assoc [ ("post", post_json); ("comments", comments_json) ]
      in
      (`OK, Yojson.Safe.to_string json)

let debate_status_filter_of_request request =
  match query_param request "status" with
  | None -> None
  | Some raw -> (
      match String.lowercase_ascii (String.trim raw) with
      | "open" -> Some Council.Debate.Open
      | "closed" -> Some Council.Debate.Closed
      | "pending" -> Some Council.Debate.Pending
      | _ -> None)

let council_debates_json request ~base_path =
  let config = Council.make_config ~base_path in
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let fetch_limit = limit + offset in
  let status_filter = debate_status_filter_of_request request in
  let debates = Council.DebateApi.list_all ~config ~status_filter ~limit:fetch_limit () in
  let paged = debates |> drop offset |> take limit in
  let items =
    List.map
      (fun (d : Council.Debate.debate) ->
        `Assoc
          [
            ("id", `String d.id);
            ("topic", `String d.topic);
            ("status", `String (Council.Debate.status_to_string d.status));
            ("argument_count", `Int (List.length d.arguments));
            ("created_at", `Float d.created_at);
            ("created_at_iso", `String (iso8601_of_unix d.created_at));
          ])
      paged
  in
  `Assoc
    [
      ("debates", `List items);
      ("count", `Int (List.length items));
      ("limit", `Int limit);
      ("offset", `Int offset);
    ]

let council_sessions_json request =
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let sessions = Council.ConsensusApi.list_active () |> drop offset |> take limit in
  let items =
    List.map
      (fun (s : Council.Consensus.session) ->
        `Assoc
          [
            ("id", `String s.id);
            ("topic", `String s.topic);
            ("initiator", `String s.initiator);
            ("votes", `Int (List.length s.votes));
            ("quorum", `Int s.quorum);
            ("threshold", `Float s.threshold);
            ("state", Council.Consensus.voting_state_to_yojson s.state);
            ("created_at", `Float s.created_at);
            ("created_at_iso", `String (iso8601_of_unix s.created_at));
          ])
      sessions
  in
  `Assoc
    [
      ("sessions", `List items);
      ("count", `Int (List.length items));
      ("limit", `Int limit);
      ("offset", `Int offset);
    ]

let council_debate_summary_json ~base_path ~debate_id =
  let (status, json) =
    Dashboard_governance.debate_detail_json ~base_path ~debate_id
  in
  let http_status =
    match status with
    | `OK -> `OK
    | `Not_found -> `Not_found
  in
  (http_status, json)

let council_session_summary_json ~base_path ~session_id =
  let (status, json) =
    Dashboard_governance.consensus_detail_json ~base_path ~session_id
  in
  let http_status =
    match status with
    | `OK -> `OK
    | `Not_found -> `Not_found
  in
  (http_status, json)

(** CORS preflight handler *)
let options_handler request reqd =
  let origin = get_origin request in
  let headers = Httpun.Headers.of_list (
    ("content-length", "0") :: cors_preflight_headers origin
  ) in
  let response = Httpun.Response.create ~headers `No_content in
  Httpun.Reqd.respond_with_string reqd response ""

let http_status_of_graphql = function
  | `OK -> `OK
  | `Bad_request -> `Bad_request

(** Shared by HTTP/2 gateway handlers that require initialized server state. *)
let get_server_state () =
  match !server_state with
  | Some s -> s
  | None -> failwith "Server state not initialized"

let handle_get_graphql _request reqd =
  let nonce =
    let rng = Random.State.make_self_init () in
    let bytes = Bytes.init 16 (fun _ -> Char.chr (Random.State.int rng 256)) in
    Base64.encode_string (Bytes.to_string bytes)
  in
  let headers = [
    ("content-security-policy", graphql_csp_header nonce);
  ] in
  let body = graphql_playground_html ~nonce in
  Http.Response.html ~headers body reqd

let handle_post_graphql request reqd =
  let origin = get_origin request in
  Http.Request.read_body_async reqd (fun body_str ->
    match !server_state with
    | None ->
        respond_json_with_cors ~status:`Internal_server_error request reqd
          {|{"error":"server state not initialized"}|}
    | Some state ->
        let response = Graphql_api.handle_request ~config:state.room_config body_str in
        let status = http_status_of_graphql response.status in
        let headers = Httpun.Headers.of_list (
          ("content-length", string_of_int (String.length response.body))
          :: graphql_headers origin
        ) in
        let http_response = Httpun.Response.create ~headers status in
        Httpun.Reqd.respond_with_string reqd http_response response.body
  )

let handle_graphql request reqd =
  match Http.Request.method_ request with
  | `GET -> handle_get_graphql request reqd
  | `POST -> handle_post_graphql request reqd
  | _ -> Http.Response.method_not_allowed reqd

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

let handle_get_mcp ?legacy_messages_endpoint ?(profile = Mcp_eio.Full) request reqd =
  Server_mcp_transport_http.handle_get_mcp ~deps:mcp_transport_http_deps
    ?legacy_messages_endpoint ~profile request reqd

let sse_simple_handler request reqd =
  Server_mcp_transport_http.sse_simple_handler ~deps:mcp_transport_http_deps
    request reqd

(** TRPG SSE poll interval in seconds *)
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

type keeper_chat_stream_request = {
  name : string;
  message : string;
  models : string list;
}

let keeper_chat_stream_error_json message =
  `Assoc
    [
      ( "error",
        `Assoc [ ("message", `String message) ] );
    ]

let contains_casefold haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop idx =
    if nlen = 0 then true
    else if idx + nlen > hlen then false
    else if String.sub haystack idx nlen = needle then true
    else loop (idx + 1)
  in
  loop 0

let keeper_stream_timeout_sec arguments =
  let default_timeout_sec =
    float_of_int
      (Keeper_config.int_of_env_default
         "MASC_TOOL_TIMEOUT_KEEPER_MSG_SEC"
         ~default:45
         ~min_v:10
         ~max_v:300)
  in
  match Safe_ops.json_float_opt "timeout_sec" arguments with
  | None -> default_timeout_sec
  | Some raw when raw <= 0.0 -> default_timeout_sec
  | Some raw ->
      let raw_sec = int_of_float (Float.ceil raw) in
      float_of_int (max 5 (min 300 raw_sec))

let execute_keeper_stream_tool ~sw ~clock ?auth_token:_ state ~agent_name ~arguments =
  let timeout_sec = keeper_stream_timeout_sec arguments in
  let start_time = Eio.Time.now clock in
  let timeout_hit = ref false in
  let success, body =
    try
      Eio.Time.with_timeout_exn clock timeout_sec (fun () ->
          let keeper_ctx : _ Tool_keeper.context =
            { config = state.Mcp_server.room_config; sw; clock }
          in
          match Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_msg" ~args:arguments with
          | Some result -> result
          | None -> (false, "masc_keeper_msg dispatch unavailable"))
    with
    | Eio.Time.Timeout ->
        timeout_hit := true;
        Log.Mcp.error "tools/call timeout: masc_keeper_msg after %.0fs" timeout_sec;
        ( false,
          Printf.sprintf
            "❌ Tool timed out after %.0fs: %s (env: MASC_TOOL_TIMEOUT_KEEPER_MSG_SEC)"
            timeout_sec "masc_keeper_msg" )
    | exn ->
        let err = Printexc.to_string exn in
        if contains_casefold err "Invalid_argument(\"MASC not initialized" then
          (false, Types.masc_error_to_string Types.NotInitialized)
        else (
          Log.Mcp.error "tools/call crashed: %s" err;
          (false, Printf.sprintf "❌ Internal error: %s" err))
  in
  let end_time = Eio.Time.now clock in
  let duration_ms = int_of_float ((end_time -. start_time) *. 1000.0) in
  let error_msg =
    if success then None
    else Some
      (Printf.sprintf "timeout=%d|duration_ms=%d"
         (if !timeout_hit then 1 else 0) duration_ms)
  in
  Audit_log.log_tool_call state.Mcp_server.room_config
    ~agent_id:agent_name ~tool_name:"masc_keeper_msg" ~success ~error_msg ();
  let telemetry_enabled =
    match Sys.getenv_opt "MASC_TELEMETRY_ENABLED" with
    | Some "false" | Some "0" -> false
    | _ -> true
  in
  if telemetry_enabled then (
    match state.Mcp_server.fs with
    | Some fs ->
        (try
           Telemetry_eio.track_tool_called ~fs state.Mcp_server.room_config
             ~tool_name:"masc_keeper_msg" ~success ~duration_ms ()
         with exn ->
           Printf.eprintf "[WARN] telemetry tracking failed: %s\n%!"
             (Printexc.to_string exn))
    | None -> ()
  );
  Tool_registry.record_call_if_known ~tool_name:"masc_keeper_msg" ~success
    ~duration_ms;
  (success, body)

let parse_keeper_chat_stream_request body_str =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string body_str in
    if not (match json with `Assoc _ -> true | _ -> false) then
      Error "request body must be a JSON object"
    else
      let name = json |> member "name" |> to_string_option |> Option.value ~default:"" |> String.trim in
      let message =
        json |> member "message" |> to_string_option |> Option.value ~default:""
        |> String.trim
      in
      let models =
        match json |> member "models" with
        | `Null -> Ok []
        | `List items ->
            let rec collect acc = function
              | [] -> Ok (List.rev acc)
              | `String model :: rest ->
                  let trimmed = String.trim model in
                  if trimmed = "" then
                    Error "models must be an array of non-empty strings"
                  else
                    collect (trimmed :: acc) rest
              | _ -> Error "models must be an array of non-empty strings"
            in
            collect [] items
        | _ -> Error "models must be an array of strings"
      in
      if name = "" then
        Error "name is required"
      else if message = "" then
        Error "message is required"
      else
        Result.map (fun models -> { name; message; models }) models
  with Yojson.Json_error e ->
    Error ("invalid json: " ^ e)

let strip_keeper_visible_reply (reply : string) =
  reply
  |> Keeper_alerting.strip_skill_route_lines
  |> Keeper_execution.strip_state_blocks_text
  |> String.trim

let split_keeper_reply_chunks (text : string) : string list =
  let len = String.length text in
  if len = 0 then
    []
  else
    let whitespace = function
      | ' ' | '\n' | '\t' -> true
      | _ -> false
    in
    let chunks = ref [] in
    let start = ref 0 in
    let last_space = ref None in
    let push stop =
      if stop > !start then
        chunks := String.sub text !start (stop - !start) :: !chunks;
      start := stop;
      last_space := None
    in
    for i = 0 to len - 1 do
      let ch = text.[i] in
      if ch = ' ' then last_space := Some i;
      let next_is_boundary =
        i + 1 >= len || whitespace text.[i + 1]
      in
      let hard_wrap =
        i - !start >= 180
        &&
        match !last_space with
        | Some idx -> idx > !start
        | None -> false
      in
      let should_break =
        (match ch with
         | '.' | '!' | '?' -> next_is_boundary
         | '\n' -> i + 1 < len && text.[i + 1] = '\n'
         | _ -> false)
        || hard_wrap
      in
      if should_break then
        match !last_space with
        | Some idx when hard_wrap -> push (idx + 1)
        | _ -> push (i + 1)
    done;
    if !start < len then
      chunks := String.sub text !start (len - !start) :: !chunks;
    List.rev !chunks |> List.filter (fun chunk -> String.trim chunk <> "")

let keeper_stream_send_raw writer mutex closed data =
  if !closed || Httpun.Body.Writer.is_closed writer then begin
    closed := true;
    false
  end else
    try
      Eio.Mutex.use_rw ~protect:true mutex (fun () ->
          Httpun.Body.Writer.write_string writer data;
          Httpun.Body.Writer.flush writer (fun _ -> ()));
      true
    with _ ->
      closed := true;
      false

let keeper_stream_send_event writer mutex closed event =
  keeper_stream_send_raw writer mutex closed (Ag_ui.event_to_sse event)

let handle_keeper_chat_stream ~sw ~clock state request reqd payload =
  let origin = get_origin request in
  let headers =
    Httpun.Headers.of_list
      ([
         ("content-type", "text/event-stream");
         ("cache-control", "no-cache");
         ("connection", "keep-alive");
         ("x-accel-buffering", "no");
       ]
      @ cors_headers origin)
  in
  let response = Httpun.Response.create ~headers `OK in
  let writer = Httpun.Reqd.respond_with_streaming reqd response in
  let mutex = Eio.Mutex.create () in
  let closed = ref false in
  let close_stream () =
    if not !closed then begin
      closed := true;
      (try Httpun.Body.Writer.close writer with _ -> ())
    end
  in
  let now_id () =
    int_of_float (Time_compat.now () *. 1000.0)
  in
  let thread_id = "keeper:" ^ payload.name in
  let run_id = Printf.sprintf "keeper-run-%d" (now_id ()) in
  let message_id = Printf.sprintf "keeper-msg-%d" (now_id ()) in
  ignore (keeper_stream_send_raw writer mutex closed "retry: 1500\n\n");
  Eio.Fiber.fork ~sw (fun () ->
      Fun.protect
        ~finally:close_stream
        (fun () ->
          ignore
            (keeper_stream_send_event writer mutex closed
               Ag_ui.(
                 make_event ~thread_id ~run_id:(Some run_id) Run_started));
          ignore
            (keeper_stream_send_event writer mutex closed
               Ag_ui.(
                 make_event ~thread_id ~run_id:(Some run_id)
                   ~message_id:(Some message_id) ~role:(Some Assistant)
                   Text_message_start));
          let args =
            `Assoc
              ([
                 ("name", `String payload.name);
                 ("message", `String payload.message);
               ]
              @
              if payload.models = [] then []
              else [ ("models", `List (List.map (fun model -> `String model) payload.models)) ])
          in
          let agent_name =
            match agent_from_request request with
            | Some raw when String.trim raw <> "" -> String.trim raw
            | _ -> "unknown"
          in
          let dispatch_result =
            try
              Ok
                (execute_keeper_stream_tool ~sw ~clock
                   ?auth_token:(auth_token_from_request request)
                   state ~agent_name ~arguments:args)
            with exn -> Error (Printexc.to_string exn)
          in
          match dispatch_result with
          | Error err ->
              ignore
                (keeper_stream_send_event writer mutex closed
                   Ag_ui.(
                     make_event ~thread_id ~run_id:(Some run_id)
                       ~custom_name:(Some "KEEPER_CHAT_ERROR")
                       ~custom_value:(Some (`Assoc [ ("message", `String err) ]))
                       Run_error))
          | Ok (false, err) ->
              ignore
                (keeper_stream_send_event writer mutex closed
                   Ag_ui.(
                     make_event ~thread_id ~run_id:(Some run_id)
                       ~custom_name:(Some "KEEPER_CHAT_ERROR")
                       ~custom_value:(Some (`Assoc [ ("message", `String err) ]))
                       Run_error))
          | Ok (true, body) -> (
              try
                let payload_json_opt =
                  try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None
                in
                let visible_reply =
                  match payload_json_opt with
                  | Some payload_json ->
                      let reply_raw =
                        payload_json |> Yojson.Safe.Util.member "reply"
                        |> Yojson.Safe.Util.to_string_option
                        |> Option.value ~default:""
                      in
                      let visible_reply =
                        if String.trim reply_raw = "" then
                          String.trim body
                        else
                          strip_keeper_visible_reply reply_raw
                      in
                      if visible_reply = "" then
                        Option.value ~default:"(empty reply)"
                          (Yojson.Safe.Util.to_string_option payload_json)
                      else
                        visible_reply
                  | None ->
                      let visible_reply = strip_keeper_visible_reply body in
                      if visible_reply = "" then "(empty reply)" else visible_reply
                in
                split_keeper_reply_chunks visible_reply
                |> List.iter (fun chunk ->
                       ignore
                         (keeper_stream_send_event writer mutex closed
                            Ag_ui.(
                              make_event ~thread_id ~run_id:(Some run_id)
                                ~message_id:(Some message_id)
                                ~delta:(Some chunk)
                                Text_message_content)));
                (match payload_json_opt with
                 | Some payload_json ->
                     ignore
                       (keeper_stream_send_event writer mutex closed
                          Ag_ui.(
                            make_event ~thread_id ~run_id:(Some run_id)
                              ~custom_name:(Some "KEEPER_REPLY_DETAILS")
                              ~custom_value:(Some payload_json)
                              Custom))
                 | None -> ());
                ignore
                  (keeper_stream_send_event writer mutex closed
                     Ag_ui.(
                       make_event ~thread_id ~run_id:(Some run_id)
                         ~message_id:(Some message_id)
                         Text_message_end));
                ignore
                  (keeper_stream_send_event writer mutex closed
                     Ag_ui.(
                       make_event ~thread_id ~run_id:(Some run_id) Run_finished))
              with exn ->
                ignore
                  (keeper_stream_send_event writer mutex closed
                     Ag_ui.(
                       make_event ~thread_id ~run_id:(Some run_id)
                         ~custom_name:(Some "KEEPER_CHAT_ERROR")
                         ~custom_value:(Some (`Assoc [ ("message", `String (Printexc.to_string exn)) ]))
                         Run_error))));
        )

(** Build routes for MCP server *)
let make_routes ~port ~host ~sw ~clock =
  Http.Router.empty
  |> Http.Router.get "/health" health_handler
  |> Http.Router.get "/metrics" (fun request reqd ->
       with_read_auth (fun _state _req reqd ->
         let body = Prometheus.to_prometheus_text () in
         Http.Response.bytes ~content_type:"text/plain; version=0.0.4; charset=utf-8" body reqd
       ) request reqd)
  |> Http.Router.get "/.well-known/agent.json" (serve_agent_card ~host ~port)
  |> Http.Router.get "/.well-known/agent-card.json" (serve_agent_card ~host ~port)
  |> Http.Router.get "/ag-ui/events" handle_ag_ui_events
  (* Dashboard sub-routes: credits and lodge must come before the SPA catchall *)
  |> Http.Router.get "/dashboard/credits" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         Http.Response.html (Credits_dashboard.html ()) reqd
       ) request reqd)
  |> Http.Router.get "/dashboard/lodge" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         Http.Response.html_cached
           ~etag:(Lodge_dashboard.etag ())
           ~request:req
           (Lodge_dashboard.html ()) reqd
       ) request reqd)
  |> Http.Router.get "/favicon.ico" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         serve_favicon req reqd
       ) request reqd)
  |> Http.Router.get "/favicon.svg" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         serve_favicon req reqd
       ) request reqd)
  (* Dashboard SPA: static assets — prefix match for /dashboard/assets/* *)
  |> Http.Router.prefix_get "/dashboard/assets/"
       (fun request reqd ->
         let req_path = Http.Request.path request in
         let prefix_len = String.length "/dashboard/assets/" in
         let filename = String.sub req_path prefix_len (String.length req_path - prefix_len) in
         if Web_dashboard.is_safe_asset_relative_path filename then
           serve_dashboard_static ("assets/" ^ filename) request reqd
         else
           Http.Response.not_found reqd)
  (* Dashboard SPA: index.html *)
  |> Http.Router.get "/dashboard" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         serve_dashboard_index req reqd
       ) request reqd)
  |> Http.Router.get "/dashboard/" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         serve_dashboard_index req reqd
       ) request reqd)
  |> Http.Router.prefix_get "/dashboard/"
       (fun request reqd ->
         with_public_read (fun _state req reqd ->
           let req_path = Http.Request.path req in
           if is_dashboard_spa_deep_link req_path then
             serve_dashboard_index req reqd
           else
             Http.Response.not_found reqd
         ) request reqd)
  |> Http.Router.get "/api/v1/credits" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         Http.Response.json (Credits_dashboard.json_api ()) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/openapi.json" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let host_header = Httpun.Headers.get req.Httpun.Request.headers "host" in
         let (resolved_host, resolved_port) = match host_header with
           | Some header -> parse_host_port (Some header) host port
           | None -> ("", 0)
         in
         let json =
           Transport.Rest.generate_openapi_document
             ~host:resolved_host ~port:resolved_port ()
           |> Yojson.Safe.to_string
         in
         Http.Response.json json reqd
       ) request reqd)
  |> Http.Router.get "/" (fun _req reqd -> Http.Response.text "MASC MCP Server" reqd)
  |> Http.Router.get "/static/css/middleware.css"
       (serve_playground_asset "static/css/middleware.css")
  |> Http.Router.get "/static/js/middleware.js"
       (serve_playground_asset "static/js/middleware.js")
  |> Http.Router.get "/graphiql/graphiql.min.css"
       (serve_graphiql_asset "graphiql.min.css")
  |> Http.Router.get "/graphiql/graphiql.min.js"
       (serve_graphiql_asset "graphiql.min.js")
  |> Http.Router.get "/graphiql/react.production.min.js"
       (serve_graphiql_asset "react.production.min.js")
  |> Http.Router.get "/graphiql/react-dom.production.min.js"
       (serve_graphiql_asset "react-dom.production.min.js")
  |> Http.Router.get "/mcp" (fun request reqd ->
       with_read_auth (fun _state req reqd -> handle_get_mcp req reqd) request reqd)
  |> Http.Router.get "/mcp/operator" handle_get_operator_mcp
  |> Http.Router.post "/" handle_post_mcp
  |> Http.Router.post "/mcp" handle_post_mcp
  |> Http.Router.post "/mcp/operator" (handle_post_mcp ~profile:Mcp_eio.Operator_remote)
  |> Http.Router.add ~path:"/graphql" ~methods:[`GET; `POST]
       ~handler:(fun request reqd ->
         with_read_auth (fun _state req reqd -> handle_graphql req reqd) request reqd)
  |> Http.Router.post "/messages" handle_post_messages
  |> Http.Router.get "/sse"
       (fun request reqd ->
         with_public_read (fun _state req reqd ->
           handle_get_mcp
             ~legacy_messages_endpoint:(legacy_messages_endpoint_url req)
             req reqd
         ) request reqd)
  |> Http.Router.get "/sse/simple" (fun request reqd ->
       with_public_read (fun _state req reqd -> sse_simple_handler req reqd) request reqd)
  (* REST API for dashboard - direct Room access *)
  |> Http.Router.get "/api/v1/status" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let config = state.Mcp_server.room_config in
         let room_state = Room.read_state config in
         let tempo = Tempo.get_tempo config in
         let json = `Assoc [
           ("cluster", `String (Option.value ~default:"unknown" (Sys.getenv_opt "MASC_CLUSTER_NAME")));
           ("project", `String room_state.project);
           ("tempo_interval_s", `Float tempo.current_interval_s);
           ("paused", `Bool room_state.paused);
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/tasks" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let config = state.Mcp_server.room_config in
         let status_filter = query_param req "status" in
         let include_done = bool_query_param req "include_done" ~default:false in
         let include_cancelled = bool_query_param req "include_cancelled" ~default:false in
         let limit = int_query_param req "limit" ~default:50 in
         let offset = int_query_param req "offset" ~default:0 in
         let tasks = Room.get_tasks_raw config in
         let filtered =
           match status_filter with
           | None -> tasks
           | Some status ->
               List.filter (fun (t : Types.task) ->
                 String.equal status (Types.string_of_task_status t.task_status)
               ) tasks
         in
         let filtered =
           match status_filter with
           | Some _ -> filtered
           | None ->
               List.filter (fun (t : Types.task) ->
                 let is_done = match t.task_status with
                   | Types.Done _ -> true
                   | _ -> false
                 in
                 let is_cancelled = match t.task_status with
                   | Types.Cancelled _ -> true
                   | _ -> false
                 in
                 (include_done || not is_done) &&
                 (include_cancelled || not is_cancelled)
               ) filtered
         in
         let total = List.length filtered in
         let page =
           filtered
           |> List.filteri (fun idx _ -> idx >= offset && idx < offset + limit)
         in
         let tasks_json = List.map (fun (t : Types.task) ->
           `Assoc [
             ("id", `String t.id);
             ("title", `String t.title);
             ("status", `String (Types.string_of_task_status t.task_status));
             ("priority", `Int t.priority);
             ("assignee", match t.task_status with
               | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } -> `String assignee
               | _ -> `Null);
           ]
         ) page in
         let json = `Assoc [
           ("tasks", `List tasks_json);
           ("limit", `Int limit);
           ("offset", `Int offset);
           ("total", `Int total);
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/agents" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let config = state.Mcp_server.room_config in
         let status_filter = query_param req "status" in
         let limit = int_query_param req "limit" ~default:50 in
         let offset = int_query_param req "offset" ~default:0 in
         let agents = Room.get_agents_raw config in
         let filtered =
           match status_filter with
           | None -> agents
           | Some status ->
               List.filter (fun (a : Types.agent) ->
                 String.equal status (Types.string_of_agent_status a.status)
               ) agents
         in
         let total = List.length filtered in
         let page =
           filtered
           |> List.filteri (fun idx _ -> idx >= offset && idx < offset + limit)
         in
         let agents_json = List.map (fun (a : Types.agent) ->
           `Assoc [
             ("name", `String a.name);
             ("status", `String (Types.string_of_agent_status a.status));
             ("current_task", match a.current_task with Some t -> `String t | None -> `Null);
           ]
         ) page in
         let json = `Assoc [
           ("agents", `List agents_json);
           ("limit", `Int limit);
           ("offset", `Int offset);
           ("total", `Int total);
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/messages" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let config = state.Mcp_server.room_config in
         let since_seq = int_query_param req "since_seq" ~default:0 in
         let limit = int_query_param req "limit" ~default:20 in
         let agent_filter = query_param req "agent" in
         let msgs = Room.get_messages_raw config ~since_seq ~limit:500 in
         let filtered =
           match agent_filter with
           | None -> msgs
           | Some agent ->
               List.filter (fun (m : Types.message) ->
                 String.equal agent m.from_agent
               ) msgs
         in
         let total = List.length filtered in
         let page = filtered |> List.filteri (fun idx _ -> idx < limit) in
         let msgs_json = List.map (fun (m : Types.message) ->
           `Assoc [
             ("from", `String m.from_agent);
             ("content", `String m.content);
             ("timestamp", `String m.timestamp);
             ("seq", `Int m.seq);
           ]
         ) page in
         let json = `Assoc [
           ("messages", `List msgs_json);
           ("limit", `Int limit);
           ("since_seq", `Int since_seq);
           ("total", `Int total);
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/events" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = Option.value ~default:"" (query_param req "room_id") in
         let after_seq = int_query_param req "after_seq" ~default:0 in
         let event_type_filter = query_param req "event_type" in
         match trpg_read_events_json ~base_dir ~room_id ~after_seq ~event_type_filter with
         | Ok json ->
             let normalized = trpg_normalize_events_json ~default_room_id:room_id json in
             respond_json_with_cors request reqd (Yojson.Safe.to_string normalized)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/events" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_append_event_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors ~status:`Created request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
         )
       ) request reqd)
  |> Http.Router.get "/api/v1/room/current" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let config = state.Mcp_server.room_config in
         let room_id = Option.value ~default:"default" (Room.read_current_room config) in
         let json = `Assoc [("ok", `Bool true); ("room_id", `String room_id)] in
         respond_json_with_cors request reqd (Yojson.Safe.to_string json)
       ) request reqd)
  |> Http.Router.post "/api/v1/room/current" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let config = state.Mcp_server.room_config in
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
              (match trpg_parse_required_string "room_id" json with
               | Error (`Bad_request, msg) ->
                   respond_json_with_cors ~status:`Bad_request request reqd
                     (Yojson.Safe.to_string (trpg_error_json msg))
               | Ok room_id ->
                   let room_id = String.trim room_id in
                   if room_id = "" then
                     respond_json_with_cors ~status:`Bad_request request reqd
                       (Yojson.Safe.to_string
                          (trpg_error_json "room_id cannot be empty"))
                   else (
                     Room.write_current_room config room_id;
                     Room.ensure_room_entry config room_id;
                     let response = `Assoc [("ok", `Bool true); ("room_id", `String room_id)] in
                     respond_json_with_cors request reqd (Yojson.Safe.to_string response)))
           with
           | Yojson.Json_error msg ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string
                    (trpg_error_json (Printf.sprintf "invalid json: %s" msg))))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/state" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         match trpg_derive_state_json ~base_dir ~room_id ~rule_module with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/lobby/catalog" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         match
           trpg_lobby_catalog_json ~base_dir ~config:state.Mcp_server.room_config ~room_id
             ~rule_module
         with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/lobby/preflight" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         let dm_keeper = query_param req "dm" in
         let player_keepers =
           query_param req "players" |> Option.value ~default:"" |> split_csv_nonempty
         in
         let models =
           query_param req "models" |> Option.value ~default:"" |> split_csv_nonempty
         in
         match
           trpg_lobby_preflight_json ~base_dir ~config:state.Mcp_server.room_config ~room_id
             ~rule_module ~dm_keeper ~player_keepers ~models
         with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/overview" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         match trpg_overview_json ~base_dir ~room_id ~rule_module with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/control/state" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         match trpg_control_state_json ~base_dir ~room_id ~rule_module with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/models" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         respond_json_with_cors request reqd
           (Yojson.Safe.to_string (trpg_available_models_json ()))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/dice/roll" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_dice_roll_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors ~status:`Created request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
         )
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/turns/advance" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_turn_advance_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors request reqd (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
         )
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/rounds/run" (fun request reqd ->
       with_public_read (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           let agent_name =
             Option.value ~default:"dashboard" (agent_from_request req)
           in
           match Eio_context.get_switch_opt (), Eio_context.get_clock_opt () with
           | Some sw, Some clock -> (
               match
                 trpg_round_run_json
                   ~state
                   ~agent_name
                   ~sw
                   ~clock
                   ~idempotency_key:
                     (get_header_any_case req.Httpun.Request.headers "idempotency-key")
                   ~body_str
               with
               | Ok json ->
                   respond_json_with_cors request reqd (Yojson.Safe.to_string json)
               | Error (`Bad_request, msg) ->
                   respond_json_with_cors ~status:`Bad_request request reqd
                     (Yojson.Safe.to_string (trpg_error_json msg))
               | Error (`Internal_server_error, msg) ->
                   respond_json_with_cors ~status:`Internal_server_error request reqd
                     (Yojson.Safe.to_string (trpg_error_json msg)))
           | _ ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string
                    (trpg_error_json "trpg runtime not initialized"))
         )
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/stream" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = Option.value ~default:"" (query_param req "room_id") in
         let after_seq = int_query_param req "after_seq" ~default:0 in
         let event_type_filter = query_param req "event_type" in
         match trpg_stream_json ~base_dir ~room_id ~after_seq ~event_type_filter with
         | Ok json ->
             let normalized = trpg_normalize_events_json ~default_room_id:room_id json in
             respond_json_with_cors request reqd (Yojson.Safe.to_string normalized)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/timeline" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let after_seq = int_query_param req "after_seq" ~default:0 in
         let event_type_filter = query_param req "event_type" in
         let actor_filter = query_param req "actor" in
         let phase_filter = query_param req "phase" in
         let limit = int_query_param req "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
         match
           trpg_timeline_json ~base_dir ~room_id ~after_seq ~event_type_filter
             ~actor_filter ~phase_filter ~limit
         with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/stream/sse" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = Option.value ~default:"" (query_param req "room_id") in
         let event_type_filter = query_param req "event_type" in
         handle_trpg_sse ~base_dir ~room_id ~event_type_filter request reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/actors/spawn" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match
             trpg_actor_spawn_json ~base_dir
               ~idempotency_key:
                 (get_header_any_case req.Httpun.Request.headers "idempotency-key")
               ~body_str
           with
           | Ok json ->
               respond_json_with_cors ~status:`Created request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg)))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/actors/claim" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_actor_claim_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors ~status:`Created request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg)))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/actors/release" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_actor_release_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg)))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/tts" (fun request reqd ->
       Http.Request.read_body_async reqd (fun body_str ->
         match trpg_tts_proxy ~body_str with
         | Ok audio_bytes ->
             let origin = get_origin request in
             Http.Response.bytes ~content_type:"audio/mpeg"
               ~headers:(cors_headers origin) audio_bytes reqd
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (_, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))))
  |> Http.Router.get "/api/v1/voice/config" (fun request reqd ->
       let status, json = voice_config_payload () in
       let status =
         match status with `OK -> `OK | `Error -> `Internal_server_error
       in
       respond_json_with_cors ~status request reqd (Yojson.Safe.to_string json))
  |> Http.Router.post "/api/v1/broadcast" (fun request reqd ->
       (* POST /api/v1/broadcast - HTTP API for external tools like autocov *)
       with_read_auth (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             let agent_name = json |> Yojson.Safe.Util.member "agent_name" |> Yojson.Safe.Util.to_string in
             let message = json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string in
             let config = state.Mcp_server.room_config in
             let _ = Room.broadcast config ~from_agent:agent_name ~content:message in
             Http.Response.json {|{"ok":true}|} reqd
           with e ->
             Http.Response.json
               (Printf.sprintf {|{"ok":false,"error":"%s"}|} (Printexc.to_string e))
               reqd
         )
       ) request reqd)
  |> Http.Router.post "/broadcast" (fun request reqd ->
       (* POST /broadcast - Alias for autocov compatibility *)
       with_read_auth (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             let agent_name = json |> Yojson.Safe.Util.member "agent_name" |> Yojson.Safe.Util.to_string in
             let message = json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string in
             let config = state.Mcp_server.room_config in
             let _ = Room.broadcast config ~from_agent:agent_name ~content:message in
             Http.Response.json {|{"ok":true}|} reqd
           with e ->
             Http.Response.json
               (Printf.sprintf {|{"ok":false,"error":"%s"}|} (Printexc.to_string e))
               reqd
         )
       ) request reqd)

  (* Batch dashboard endpoint: single request replaces 4 separate API calls *)
  |> Http.Router.get "/api/v1/dashboard" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json =
           `Assoc
             [
               ("error", `String "dashboard batch contract removed");
               ("message", `String "Use /api/v1/dashboard/shell and surface-specific projection endpoints.");
             ]
         in
         Http.Response.json ~status:`Gone ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/shell" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_shell_http_json state.Mcp_server.room_config in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/room-truth" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_room_truth_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/execution" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_execution_http_json ~state ~sw ~clock request in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/memory" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = dashboard_memory_http_json req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/governance" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let json = dashboard_governance_http_json req ~base_path in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/planning" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_planning_http_json req ~config:state.Mcp_server.room_config in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/semantics" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = dashboard_semantics_http_json () in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/mission" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_mission_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/session" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_session_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/tools" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json =
           dashboard_tools_http_json
             ?actor:(agent_from_request request)
             state.Mcp_server.room_config
         in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/mission/briefing" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_mission_briefing_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/proof" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_proof_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/keepers/chat/stream" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           match parse_keeper_chat_stream_request body_str with
           | Ok payload ->
               handle_keeper_chat_stream ~sw ~clock state request reqd payload
           | Error message ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (keeper_chat_stream_error_json message))
         )
       ) request reqd)

  (* Tool metrics — unified registry stats for dashboard (P4 Phase 4.5) *)
  |> Http.Router.get "/api/v1/tool-metrics" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Tool_unified.summary_report () in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/mdal/loops" (fun request reqd ->
       with_public_read (fun state req reqd ->
         match mdal_loops_json ~config:state.Mcp_server.room_config req with
         | Ok json -> Http.Response.json (Yojson.Safe.to_string json) reqd
         | Error msg ->
             Http.Response.json ~status:`Bad_request
               (Yojson.Safe.to_string (mdal_loops_error_json msg)) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_snapshot_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/summary" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_summary_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/help" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = command_plane_help_http_json () in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/topology" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_topology_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/units" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_units_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/operations" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_operations_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/detachments" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_detachments_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/detachment-status" (fun request reqd ->
       with_public_read (fun state req reqd ->
         match command_plane_detachment_status_http_json ~state req with
         | Ok json ->
             Http.Response.json ~compress:true ~request:req
               (Yojson.Safe.to_string json) reqd
         | Error message ->
             Http.Response.json ~compress:true ~status:`Bad_request ~request:req
               (Yojson.Safe.to_string (command_plane_error_json message))
               reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/decisions" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_decisions_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/capacity" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_capacity_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/alerts" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_alerts_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/traces" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_traces_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/swarm" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_swarm_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/orchestra" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_orchestra_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/chains/summary" (fun request reqd ->
       with_public_read (fun state req reqd ->
         match command_plane_chain_summary_http_json ~state req with
         | Ok json ->
             Http.Response.json ~compress:true ~request:req
               (Yojson.Safe.to_string json) reqd
         | Error message ->
             Http.Response.json ~status:(chain_http_error_status message) ~request:req
               (Yojson.Safe.to_string (command_plane_error_json message))
               reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/chains/events" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         command_plane_chain_events_http ~request:req reqd
       ) request reqd)

  |> Http.Router.prefix_get "/api/v1/chains/runs/" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let req_path = Http.Request.path req in
         let prefix = "/api/v1/chains/runs/" in
         let run_id =
           String.sub req_path (String.length prefix)
             (String.length req_path - String.length prefix)
         in
         match command_plane_chain_run_http_json ~state req run_id with
         | Ok json ->
             Http.Response.json ~compress:true ~request:req
               (Yojson.Safe.to_string json) reqd
         | Error message ->
             Http.Response.json ~status:(chain_http_error_status message) ~request:req
               (Yojson.Safe.to_string (command_plane_error_json message))
               reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/command-plane/units" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_unit_define_http_json ~state req ~args with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
        )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/units/reparent" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_unit_reparent_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/units/reassign" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_unit_reassign_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_start_http_json ~state req ~args with
             | Ok json ->
                 respond_json_with_cors ~status:`Created request reqd
                   (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
        )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/pause" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_pause_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/resume" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_resume_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/stop" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_stop_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/finalize" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_finalize_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/checkpoint" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match
               command_plane_operation_checkpoint_http_json ~state req ~args
             with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
        )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/plan" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_plan_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/assign" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_assign_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/rebalance" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_rebalance_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/escalate" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_escalate_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/recall" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_recall_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/tick" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_tick_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/policy" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_policy_status_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/approve" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_approve_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/deny" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_deny_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/update" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_update_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/freeze" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_freeze_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/kill-switch" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_kill_switch_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.get "/api/v1/operator" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = operator_snapshot_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/operator/digest" (fun request reqd ->
       with_public_read (fun state req reqd ->
         match operator_digest_http_json ~state ~sw ~clock req with
         | Ok json ->
             Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
         | Error message ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (operator_error_json message))
       ) request reqd)

  |> Http.Router.post "/api/v1/operator/action" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match operator_action_http_json ~state ~sw ~clock req ~args with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (operator_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (operator_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/operator/confirm" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match operator_confirm_http_json ~state ~sw ~clock req ~args with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (operator_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (operator_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)
  |> Http.Router.get "/api/v1/council/debates" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let json = council_debates_json req ~base_path in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/council/sessions" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = council_sessions_json req in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let hearth = query_param req "hearth" in
         let sort_by = board_sort_order_of_request req in
         let exclude_system = bool_query_param req "exclude_system" ~default:false in
         let limit = int_query_param req "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
         let offset = int_query_param req "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
         let fetch_limit = board_fetch_limit ~exclude_system ~limit ~offset in
         let posts = Board_dispatch.list_posts ?hearth ~sort_by ~limit:fetch_limit () in
         let posts = filter_board_posts ~exclude_system posts in
         let karma_map = Board_dispatch.get_all_karma () in
         let get_karma author =
           Option.value ~default:0 (List.assoc_opt author karma_map)
         in
         let paged = posts |> drop offset |> take limit in
         let posts_json =
           List.map
             (fun (p : Board.post) ->
               let author = Board.Agent_id.to_string p.author in
               board_post_dashboard_json ~author_karma:(get_karma author) p)
             paged
         in
         let json = `Assoc [
           ("posts", `List posts_json);
           ("count", `Int (List.length posts_json));
           ("limit", `Int limit);
           ("offset", `Int offset);
           ("sort_by", `String (board_sort_label sort_by));
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board/hearths" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         let hearths = Board_dispatch.list_hearths () in
         let json = `Assoc [
           ("hearths", `List (List.map (fun (name, count) ->
             `Assoc [("name", `String name); ("count", `Int count)]
           ) hearths));
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board/flairs" (fun _request reqd ->
       let flairs = List.map Board.flair_to_yojson Board.available_flairs in
       let json = `Assoc [("flairs", `List flairs)] in
       Http.Response.json (Yojson.Safe.to_string json) reqd)


  (* Board write APIs — used by Bevy Viewer *)
  |> Http.Router.post "/api/v1/tools/masc_board_vote" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let (ok, msg) = Tool_board.handle_tool "masc_board_vote" args in
             let status = if ok then `OK else `Bad_request in
             respond_json_with_cors ~status request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool ok); ("message", `String msg)
               ]))
           with exn ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool false);
                 ("message", `String (Printexc.to_string exn))
               ]))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/tools/masc_board_comment" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let (ok, msg) = Tool_board.handle_tool "masc_board_comment" args in
             let status = if ok then `Created else `Bad_request in
             respond_json_with_cors ~status request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool ok); ("message", `String msg)
               ]))
           with exn ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool false);
                 ("message", `String (Printexc.to_string exn))
               ]))
         )
       ) request reqd)
  |> Http.Router.get "/api/v1/karma" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         let karma_list = Board_dispatch.get_all_karma () in
         let sorted = List.sort (fun (_, a) (_, b) -> compare b a) karma_list in
         let json = `Assoc [
           ("karma", `List (List.map (fun (agent, k) ->
             `Assoc [("agent", `String agent); ("karma", `Int k)]
           ) sorted));
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  (* Lodge Agents REST API — GET public, POST admin *)
  |> Http.Router.add ~path:"/api/v1/lodge/agents" ~methods:[`GET; `POST]
       ~handler:(fun request reqd ->
         match request.Httpun.Request.meth with
         | `GET ->
           with_public_read (fun _state _req reqd ->
             match Lodge_heartbeat.load_lodge_agents_full () with
             | Ok json ->
                 Http.Response.json (Yojson.Safe.to_string json) reqd
             | Error msg ->
                 Http.Response.json ~status:`Internal_server_error
                   (Printf.sprintf {|{"error":"%s"}|} msg) reqd
           ) request reqd
         | `POST ->
           with_admin_auth (fun _state _req reqd ->
             Http.Request.read_body_async reqd (fun body_str ->
               try
                 let json = Yojson.Safe.from_string body_str in
                 let open Yojson.Safe.Util in
                 let name = json |> member "name" |> to_string in
                 let emoji = json |> member "emoji" |> to_string in
                 let korean_name =
                   match json |> member "koreanName" with
                   | `String s -> Some s | _ -> None
                 in
                 let traits =
                   json |> member "traits" |> to_list |> List.map to_string
                 in
                 let interests =
                   try json |> member "interests" |> to_list
                       |> List.map to_string
                   with Yojson.Safe.Util.Type_error _ | Not_found -> []
                 in
                 let activity_level =
                   match json |> member "activityLevel" with
                   | `Float f -> f | `Int i -> float_of_int i | _ -> 0.7
                 in
                 let preferred_hours =
                   json |> member "preferredHours" |> to_list
                   |> List.map to_int
                 in
                 let peak_hour =
                   match json |> member "peakHour" with
                   | `Int i -> Some i | _ -> None
                 in
                 let model =
                   match json |> member "model" with
                   | `String s -> s | _ -> "glm-4.7-flash:latest"
                 in
                 let personality_hint =
                   match json |> member "personalityHint" with
                   | `String s -> Some s | _ -> None
                 in
                 let primary_value =
                   match json |> member "primaryValue" with
                   | `String s -> Some s | _ -> None
                 in
                 let name_re = Str.regexp "^[a-z][a-z0-9-]*$" in
                 let name_len = String.length name in
                 if name_len < 2 || name_len > 20
                    || not (Str.string_match name_re name 0) then
                   Http.Response.json ~status:`Bad_request
                     {|{"error":"name: 2-20 lowercase + hyphens"}|} reqd
                 else if String.length emoji = 0 then
                   Http.Response.json ~status:`Bad_request
                     {|{"error":"emoji is required"}|} reqd
                 else if traits = [] then
                   Http.Response.json ~status:`Bad_request
                     {|{"error":"at least one trait required"}|} reqd
                 else if preferred_hours = [] then
                   Http.Response.json ~status:`Bad_request
                     {|{"error":"at least one preferredHour"}|} reqd
                 else if activity_level < 0.1 || activity_level > 1.0 then
                   Http.Response.json ~status:`Bad_request
                     {|{"error":"activityLevel: 0.1-1.0"}|} reqd
                 else if List.exists (fun h -> h < 0 || h > 23)
                           preferred_hours then
                   Http.Response.json ~status:`Bad_request
                     {|{"error":"hours: 0-23"}|} reqd
                 else begin
                   match Lodge_heartbeat.create_agent_graphql
                           ~name ~emoji ~korean_name ~traits ~interests
                           ~activity_level ~preferred_hours ~peak_hour
                           ~model ~personality_hint ~primary_value () with
                   | Ok agent_json ->
                       Http.Response.json ~status:`Created
                         (Yojson.Safe.to_string (`Assoc [
                           ("ok", `Bool true);
                           ("agent", agent_json);
                         ])) reqd
                   | Error msg ->
                       Http.Response.json ~status:`Internal_server_error
                         (Printf.sprintf {|{"error":"%s"}|} msg) reqd
                 end
               with
               | Yojson.Safe.Util.Type_error (msg, _) ->
                   Http.Response.json ~status:`Bad_request
                     (Printf.sprintf {|{"error":"Invalid: %s"}|} msg)
                     reqd
               | Yojson.Json_error msg ->
                   Http.Response.json ~status:`Bad_request
                     (Printf.sprintf {|{"error":"Bad JSON: %s"}|} msg)
                     reqd
               | e ->
                   Http.Response.json ~status:`Internal_server_error
                     (Printf.sprintf {|{"error":"%s"}|}
                       (Printexc.to_string e)) reqd
             )
           ) request reqd
         | _ -> Http.Response.method_not_allowed reqd)
