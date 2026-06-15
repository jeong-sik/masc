(** MASC MCP Server - Eio Native Entry Point
    MCP Streamable HTTP Transport with Eio concurrency (OCaml 5.x)

    Uses h2-eio for HTTP/2 with unlimited SSE streams per connection.
    HTTP/2 multiplexing eliminates browser's 6-connection-per-domain limit.
*)

[@@@warning "-32-69"]  (* Suppress unused values/fields during migration *)

open Cmdliner

(** Module aliases *)
module Http = Masc.Http_server_eio
module Http_h2 = Masc.Http_server_h2
module Mcp_server = Masc.Mcp_server
module Mcp_eio = Masc.Mcp_server_eio
module Workspace = Masc.Workspace
module Workspace_utils = Workspace_utils
module Keeper_meta_store = Masc.Keeper_meta_store
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_memory = Masc.Keeper_memory
module Keeper_execution = Masc.Keeper_execution
module Keeper_runtime = Masc.Keeper_runtime
module Tool_operator = Masc.Tool_operator
module Operator_control = Operator_control
module Dashboard_execution = Dashboard_execution
module Dashboard_briefing = Dashboard_briefing
(* module Dashboard_proof removed *)
module Dashboard_briefing_sections = Dashboard_briefing_sections
module Build_identity = Masc.Build_identity
module Auth_login = Masc.Auth_login
module Keeper_msg_async = Masc.Keeper_msg_async
module Keeper_status_bridge = Masc.Keeper_status_bridge
module Keeper_tool_call_log = Masc.Keeper_tool_call_log
module Graphql_api = Masc.Graphql_api
module Types = Masc_domain
module Tempo = Masc.Tempo
module Auth = Masc.Auth
module Board = Masc.Board
module Board_curation = Masc.Board_curation
module Board_dispatch = Masc.Board_dispatch
module Task = Masc.Task
module Http_negotiation = Mcp_transport_protocol.Http_negotiation
module Progress = Masc.Progress
module Sse = Masc.Sse
module Safe_ops = Safe_ops
module Tool_board = Board_tool
module Transport_metrics = Masc.Transport_metrics
module Server_mcp_transport_http = Server_mcp_transport_http


(* ============================================ *)
(* Extracted modules (lib/)                      *)
(* ============================================ *)
include Masc.Server_utils
include Server_auth
include Server_voice_config
include Server_dashboard_http
module Server_h2_gateway = Server_h2_gateway
module Server_runtime_bootstrap = Server_runtime_bootstrap
module Server_routes_http_runtime = Server_routes_http_runtime
module Server_startup_takeover = Server_startup_takeover

let mcp_protocol_versions = Server_mcp_transport_http.mcp_protocol_versions

let mcp_protocol_version_default =
  Server_mcp_transport_http.mcp_protocol_version_default

let default_base_path = Server_mcp_transport_http.default_base_path

let implicit_base_path_resolution_source () = "implicit_base_path"

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

let get_protocol_version = Server_mcp_transport_http.get_protocol_version

let get_protocol_version_for_session =
  Server_mcp_transport_http.get_protocol_version_for_session

module Server_routes_http = Server_routes_http

open Server_routes_http

(* Issue #8403: derive probe exemptions from Server_health_paths SSOT
   so a renamed probe stays exempt from rate limits without a separate
   manual edit here. *)
let is_rate_limit_exempt path =
  String.equal path "/health"
  || Server_health_paths.is_public path

(** [safe_reqd_respond reqd response body] guards all direct
    [Httpun.Reqd.respond_with_string] calls in the main request handler
    against the "invalid state, currently handling error" [Failure] that
    httpun raises when the reqd has already entered its error-handling path
    (e.g. client disconnect during a long OAS turn — 2026-05-05 cycle9
    FATAL race, also see [Http_server_eio.safe_respond_with_string]).
    [Eio.Cancel.Cancelled] is always re-raised. *)
let safe_reqd_respond reqd response body =
  try Httpun.Reqd.respond_with_string reqd response body
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Failure msg ->
      Log.Server.warn
        "[http] reqd respond skipped (invalid state; 2026-05-05 OAS cancel race): %s"
        msg
  | exn ->
      Log.Server.warn "[http] reqd respond unexpected exception: %s"
        (Printexc.to_string exn)

(** Returns true if the request was rate-limited and a 429 response was
    sent on [reqd]. Caller should short-circuit further handling in that
    case. Health-probe paths are always allowed through.

    Enforces two complementary rate limits:
    1. Per-client IP (via [client_addr]) — protects against volumetric abuse.
    2. Per-agent bearer token (via Authorization header) — enforces per-agent
       quotas regardless of source IP, complementing the IP-level check. *)
let try_rate_limit_block ~path ~client_addr ~request reqd =
  if is_rate_limit_exempt path then false
  else
    let rl_key = Masc.Rate_limit.key_of_sockaddr client_addr in
    if not (Masc.Rate_limit.check_global ~key:rl_key) then begin
      let body = Masc.Rate_limit.too_many_requests_body () in
      let rl_headers = Masc.Rate_limit.headers_global ~key:rl_key in
      let headers = Httpun.Headers.of_list (
        ("content-type", "application/json") ::
        ("content-length", string_of_int (String.length body)) ::
        rl_headers
      ) in
      safe_reqd_respond reqd
        (Httpun.Response.create ~headers `Too_many_requests) body;
      true
    end else
      match auth_token_from_request request with
      | None -> false
      | Some token ->
          match Masc.Rate_limit.agent_key_of_token_or_name ~token () with
          | None -> false
          | Some agent_key ->
              if Masc.Rate_limit.check_agent_global ~key:agent_key then false
              else begin
                let body = Masc.Rate_limit.too_many_agent_requests_body () in
                let rl_headers =
                  Masc.Rate_limit.headers_agent_global ~key:agent_key
                in
                let headers =
                  Httpun.Headers.of_list
                    (("content-type", "application/json")
                    :: ("content-length", string_of_int (String.length body))
                    :: rl_headers)
                in
                safe_reqd_respond reqd
                  (Httpun.Response.create ~headers `Too_many_requests)
                  body;
                true
              end

(** Path predicate: requests that go through the MCP transport surface
    (HTTP-based sessions, SSE, JSON-RPC messages) and therefore must pass
    origin and protocol-version checks. *)
let is_mcp_like_path path =
  String.equal path "/mcp"
  || String.equal path "/mcp/managed"
  || String.equal path "/mcp/operator"
  || String.equal path "/sse"

(** Returns true if the request failed origin or protocol-version
    validation and the corresponding error response was sent on [reqd].
    Caller should short-circuit further handling in that case. *)
let try_mcp_validation_block ~is_mcp_like ~request ~protocol_version ~origin reqd =
  if is_mcp_like && not (validate_origin request) then begin
    let body = json_rpc_error Masc.Mcp_error_code.Invalid_request "Invalid origin" in
    let headers = Httpun.Headers.of_list (
      ("content-length", string_of_int (String.length body))
      :: json_headers "-" protocol_version origin
    ) in
    let response = Httpun.Response.create ~headers `Forbidden in
    safe_reqd_respond reqd response body;
    true
  end
  else if is_mcp_like && request.Httpun.Request.meth <> `OPTIONS &&
          not (is_valid_protocol_version protocol_version) then begin
    let body = json_rpc_error Masc.Mcp_error_code.Invalid_request "Unsupported protocol version" in
    let headers = Httpun.Headers.of_list (
      ("content-length", string_of_int (String.length body))
      :: json_headers "-" protocol_version origin
    ) in
    let response = Httpun.Response.create ~headers `Bad_request in
    safe_reqd_respond reqd response body;
    true
  end
  else false

let header_contains_token headers name token =
  match get_header_any_case headers name with
  | None -> false
  | Some value ->
    value
    |> String.split_on_char ','
    |> List.exists (fun part ->
         String.equal
           (String.lowercase_ascii (String.trim part))
           (String.lowercase_ascii token))

let header_equals_token headers name token =
  match get_header_any_case headers name with
  | None -> false
  | Some value ->
    String.equal
      (String.lowercase_ascii (String.trim value))
      (String.lowercase_ascii token)

let is_websocket_upgrade_request request =
  let headers = request.Httpun.Request.headers in
  header_contains_token headers "connection" "upgrade"
  && header_equals_token headers "upgrade" "websocket"

let respond_ws_upgrade_unavailable ?(message = "websocket transport disabled") reqd =
  let body =
    Yojson.Safe.to_string (`Assoc [ ("error", `String message) ])
  in
  let headers =
    Httpun.Headers.of_list
      [ ("content-type", "application/json")
      ; ("content-length", string_of_int (String.length body))
      ]
  in
  let response = Httpun.Response.create ~headers `Service_unavailable in
  safe_reqd_respond reqd response body

let handle_websocket_upgrade reqd =
  if not (Transport_metrics.ws_enabled ())
  then respond_ws_upgrade_unavailable reqd
  else
    respond_ws_upgrade_unavailable
      ~message:"same-origin websocket upgrade is disabled; use /ws discovery ws_url"
      reqd

(** Method/path dispatcher for MCP-validated requests. Caller is
    responsible for rate limiting and origin/protocol-version checks
    before invoking this function. *)
let dispatch_route ~router ~request ~path reqd =
  match request.Httpun.Request.meth, path with
  | `OPTIONS, _ -> options_handler request reqd
  | `GET, "/ws" when is_websocket_upgrade_request request ->
    handle_websocket_upgrade reqd
  | `GET, "/ws" ->
    let body =
      Server_routes_http_runtime.websocket_discovery_json request
      |> Yojson.Safe.to_string
    in
    let headers = Httpun.Headers.of_list [
      ("content-type", "application/json");
      ("content-length", string_of_int (String.length body));
    ] in
    let response = Httpun.Response.create ~headers `OK in
    safe_reqd_respond reqd response body
  | `POST, "/webrtc/offer" when Server_webrtc_transport.is_enabled () ->
    Http.Request.read_body_async reqd (fun body ->
      match Server_webrtc_transport.handle_offer_request body with
      | Ok json -> Http.Response.json json reqd
      | Error msg ->
        Http.Response.json ~status:`Bad_request
          (Printf.sprintf {|{"error":"%s"}|} msg) reqd)
  | `POST, "/webrtc/answer" when Server_webrtc_transport.is_enabled () ->
    Http.Request.read_body_async reqd (fun body ->
      match Server_webrtc_transport.handle_answer_request body with
      | Ok json -> Http.Response.json json reqd
      | Error msg ->
        Http.Response.json ~status:`Bad_request
          (Printf.sprintf {|{"error":"%s"}|} msg) reqd)
  | `DELETE, "/mcp" -> handle_delete_mcp request reqd
  | `DELETE, "/mcp/managed" ->
      handle_delete_mcp
        ~profile:Server_mcp_transport_http.Managed_agent request reqd
  | `DELETE, "/mcp/operator" ->
      handle_delete_mcp
        ~profile:Server_mcp_transport_http.Operator_remote request reqd
  | `GET, "/api/v1/board/flairs" ->
      let flairs = List.map Board.flair_to_yojson Board.available_flairs in
      let json = `Assoc [("flairs", `List flairs)] in
      Http.Response.json (Yojson.Safe.to_string json) reqd
  | `GET, "/api/v1/board/hearths" ->
      let hearths = Board_dispatch.list_hearths () in
      let json = `Assoc [
        ("hearths", `List (List.map (fun (name, count) ->
          `Assoc [("name", `String name); ("count", `Int count)]
        ) hearths));
      ] in
      Http.Response.json (Yojson.Safe.to_string json) reqd
  | `GET, "/api/v1/board/curation" ->
      let json =
        match Board_dispatch.latest_curation_snapshot () with
        | None -> `Assoc [ ("snapshot", `Null) ]
        | Some snap ->
            `Assoc [ ("snapshot", Board_curation.snapshot_to_yojson snap) ]
      in
      Http.Response.json (Yojson.Safe.to_string json) reqd
  | `GET, "/api/v1/board/sub-boards" ->
      let sub_boards = Board_dispatch.list_sub_boards () in
      let json =
        `Assoc
          [
            ( "sub_boards",
              `List (List.map Board.sub_board_to_yojson sub_boards) );
          ]
      in
      Http.Response.json (Yojson.Safe.to_string json) reqd
  | `GET, "/api/v1/board/karma/ledger" ->
      let agent = query_param request "agent" in
      let limit =
        int_query_param request "limit" ~default:500 |> clamp ~min_v:1 ~max_v:5000
      in
      let events = Board_dispatch.get_karma_ledger ?agent ~limit () in
      let totals =
        Board_dispatch.get_all_karma ()
        |> List.sort (fun (_, a) (_, b) -> compare b a)
      in
      let json =
        `Assoc
          [
            ("events", `List (List.map Board.karma_event_to_yojson events));
            ("count", `Int (List.length events));
            ("scoring_rule", `String "up=+1,down=0");
            ( "totals",
              `List
                (List.map
                   (fun (agent_name, k) ->
                     `Assoc
                       [ ("agent", `String agent_name); ("karma", `Int k) ])
                   totals) );
          ]
      in
      Http.Response.json (Yojson.Safe.to_string json) reqd
  | `POST, "/api/v1/board/reactions" ->
      Http.Request.read_body_async reqd (fun body ->
        try
          let args = Yojson.Safe.from_string body in
          let target_type_raw =
            Option.value ~default:""
              (Safe_ops.json_string_opt "target_type" args)
          in
          let target_id =
            Option.value ~default:"" (Safe_ops.json_string_opt "target_id" args)
          in
          let user_id =
            Option.value ~default:"" (Safe_ops.json_string_opt "user_id" args)
          in
          let emoji =
            Option.value ~default:"" (Safe_ops.json_string_opt "emoji" args)
          in
          match Board.reaction_target_type_of_string_opt target_type_raw with
          | None ->
              Http.Response.json ~status:`Bad_request
                {|{"error":"target_type must be post or comment"}|} reqd
          | Some target_type ->
              (match
                 Board_dispatch.toggle_reaction ~target_type ~target_id
                   ~user_id ~emoji
               with
               | Ok result ->
                   Http.Response.json
                     (Yojson.Safe.to_string
                        (Board.reaction_toggle_result_to_yojson result))
                     reqd
               | Error e ->
                   Http.Response.json ~status:`Bad_request
                     (Yojson.Safe.to_string
                        (`Assoc
                           [
                             ("error", `String (Tool_board.board_error_to_string e));
                           ]))
                     reqd)
        with
        | Yojson.Json_error msg ->
            Http.Response.json ~status:`Bad_request
              (Yojson.Safe.to_string
                 (`Assoc [ ("error", `String ("invalid JSON: " ^ msg)) ]))
              reqd)
  | `GET, "/api/v1/board/reactions" ->
      let target_type_raw =
        Option.value ~default:"" (query_param request "target_type")
      in
      let target_id =
        Option.value ~default:"" (query_param request "target_id")
      in
      let user_id = query_param request "user_id" in
      (match Board.reaction_target_type_of_string_opt target_type_raw with
       | None ->
           Http.Response.json ~status:`Bad_request
             {|{"error":"target_type must be post or comment"}|} reqd
       | Some target_type ->
           (match
              Board_dispatch.list_reactions ~target_type ~target_id ?user_id ()
            with
            | Ok summary ->
                let json =
                  `Assoc
                    [
                      ( "reactions",
                        `List (List.map Board.reaction_summary_to_yojson summary) );
                    ]
                in
                Http.Response.json (Yojson.Safe.to_string json) reqd
            | Error e ->
                Http.Response.json ~status:`Bad_request
                  (Yojson.Safe.to_string
                     (`Assoc
                        [
                          ("error", `String (Tool_board.board_error_to_string e));
                        ]))
                  reqd))
  | `GET, p when String.length p > 14 && String.sub p 0 14 = "/api/v1/board/" ->
      let post_id = String.sub p 14 (String.length p - 14) in
      let format = Option.value ~default:"nested" (query_param request "format") in
      let voter = board_voter_query request in
      let config =
        Option.map (fun state -> (Mcp_server.workspace_config state)) !server_state
      in
      let (status, body) =
        board_post_detail_json ~include_moderation:false ~blind_votes:false
          ~config ~voter ~response_format:format ~post_id
      in
      Http.Response.json ~status body reqd
  | _ -> Http.Router.dispatch router request reqd

let log_late_response_failure ~context msg =
  Log.Http.warn "%s: response already unwritable; skipped late response (%s)"
    context msg

let try_internal_error_response reqd msg =
  try Http.Response.internal_error msg reqd with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> (
      match Http.Late_response.classify_write_failure exn with
      | Some failure_msg ->
          log_late_response_failure ~context:"main_eio internal_error"
            failure_msg
      | None ->
          Log.Http.warn "main_eio internal_error response failed: %s"
            (Printexc.to_string exn))

(** Extended router to handle OPTIONS *)
let make_extended_handler routes =
  fun client_addr gluten_reqd ->
    let reqd = gluten_reqd.Gluten.Reqd.reqd in
    let request = Httpun.Reqd.request reqd in
    (* Rate limiting: enforce before any auth or routing. *)
    let path = Http.Request.path request in
    if try_rate_limit_block ~path ~client_addr ~request reqd then ()
    else
    try
      let is_mcp_like = is_mcp_like_path path in
      let session_id_for_version = get_session_id_any request in
      let protocol_version =
        get_protocol_version_for_session ?session_id:session_id_for_version request
      in
      let origin = get_origin request in
      if try_mcp_validation_block ~is_mcp_like ~request ~protocol_version ~origin reqd then ()
      else dispatch_route ~router:routes ~request ~path reqd
    with
    (* Re-raise cancellation so Eio structured concurrency propagates cleanly.
       Previously the catch-all swallowed Cancelled and tried to write a 500
       response; that masks shutdown signals and interferes with per-connection
       switch cleanup. *)
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> (
      let msg = Printexc.to_string exn in
      match Http.Late_response.classify_write_failure exn with
      | Some failure_msg ->
          log_late_response_failure ~context:"main_eio request handler"
            failure_msg
      | None -> try_internal_error_response reqd msg)

(** Main server loop *)
let run_server ~sw ~env ~host ~port ~base_path =
  (* Use the parent switch directly so that ALL fibers spawned by
     Server_runtime_bootstrap (background maintenance, keeper loops,
     dashboard refresh, etc.) are children of this switch.  When
     Eio.Fiber.first cancels the run_server fiber on SIGTERM, the
     switch is cancelled too, which propagates Cancel to every
     child fiber — preventing the 10s force-exit timeout. *)
  try
    Server_runtime_bootstrap.run ~sw ~env ~host ~port ~base_path ~make_routes
      ~make_request_handler:make_extended_handler
      ~make_h2_request_handler:Server_h2_gateway.make_request_handler
      ~make_h2_error_handler:Server_h2_gateway.make_error_handler
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Server.error "[main] keeper bootstrap failed (continuing without keepers): %s" (Printexc.to_string exn)

(** CLI options *)
let port =
  let doc = "Port to listen on" in
  Arg.(value & opt int (Env_config_core.masc_http_port_int ()) & info ["p"; "port"] ~docv:"PORT" ~doc)

let host =
  let default = Env_config.masc_host () in
  let doc =
    "Host/IP to bind. Defaults to loopback (`127.0.0.1`). Use `0.0.0.0` or `::` only when you also enable workspace auth with `require_token=true`."
  in
  Arg.(value & opt string default & info ["host"] ~docv:"HOST" ~doc)

let base_path =
  let doc =
    "Workspace root for MASC data. Runtime state lives under <base-path>/.masc; do not pass the .masc directory itself."
  in
  Arg.(value & opt string (default_base_path ()) & info ["base-path"] ~docv:"PATH" ~doc)

let login_json =
  let doc = "Emit machine-readable JSON instead of text output" in
  Arg.(value & flag & info ["json"] ~doc)

let parse_login_role value =
  match Masc_domain.agent_role_of_string (String.lowercase_ascii value) with
  | Ok role -> Ok role
  | Error msg -> Error (`Msg msg)

let login_role =
  let doc = "Role for the minted bearer token: admin or worker" in
  let role_printer fmt role =
    Format.pp_print_string fmt (Masc_domain.agent_role_to_string role)
  in
  let role_conv = Arg.conv (parse_login_role, role_printer) in
  Arg.(value & opt role_conv Masc_domain.Admin & info ["role"] ~docv:"ROLE" ~doc)

let login_agent =
  let doc = "Agent identity bound to the minted bearer token" in
  Arg.(
    value
    & opt string "local-admin"
    & info ["agent"] ~docv:"AGENT" ~doc)

let login_shell =
  let doc = "Emit shell export commands only" in
  Arg.(value & flag & info ["shell"] ~doc)

let login_client_env =
  let doc =
    "Env var name your MCP client reads to pick up the minted bearer \
     token. Required; the server holds no list of \"known\" MCP \
     clients. Example: MASC_TOKEN or any \
     operator-chosen name. The value is \
     rendered verbatim into the shell exports and JSON output."
  in
  Arg.(
    required
    & opt (some string) None
    & info ["client-env"] ~docv:"VAR" ~doc)

let login_no_expiry =
  let doc =
    "Mint a long-lived token without an [expires_at] field. \
     Appropriate for long-running local MCP daemons that cannot \
     easily refresh on expiry. Omit for the default expiring policy."
  in
  Arg.(value & flag & info ["no-expiry"] ~doc)

(** Graceful shutdown exception *)
(* Shutdown exception removed: graceful shutdown returns normally from
   await_shutdown_signal, letting Eio.Fiber.first cancel run_server. *)

let acquire_pid_lock port =
  match Server_startup_takeover.acquire_pid_lock port with
  | Server_startup_takeover.Acquired -> ()
  | Server_startup_takeover.Already_running { pid } ->
      Log.legacy_stderr ~level:Log.Error ~module_name:"Server"
        (Printf.sprintf
           "[FATAL] Another MASC server (PID %d) is already running on port %d. Kill it first: kill %d"
           pid port pid);
      exit 1

let acquire_base_path_lock base_path =
  match Server_startup_takeover.acquire_base_path_lock base_path with
  | Server_startup_takeover.Acquired -> ()
  | Server_startup_takeover.Already_running { pid } ->
      Log.legacy_stderr ~level:Log.Error ~module_name:"Server"
        (Printf.sprintf
           "[FATAL] Another MASC server (PID %d) already owns base path %s. Kill it first: kill %d"
           pid base_path pid);
      exit 1

(** Reject base_path that points to the server's own source repo.
    Detects by checking if the running executable lives under base_path/_build/.
    Runtime state (.masc/keepers, traces, logs) must not pollute the repo. *)
let guard_self_repo_base_path base_path =
  let base_path = Env_config.normalize_masc_base_path_input base_path in
  let abs_base =
    try Unix.realpath base_path with Unix.Unix_error _ -> base_path
  in
  let abs_exe =
    try Unix.realpath Sys.executable_name with Unix.Unix_error _ -> ""
  in
  let build_prefix = abs_base ^ "/_build/" in
  let is_self_repo =
    abs_exe <> ""
    && String.length abs_exe > String.length build_prefix
    && String.sub abs_exe 0 (String.length build_prefix) = build_prefix
  in
  if is_self_repo then begin
    Printf.eprintf
       "[FATAL] --base-path points to the server's own source repo: %s\n\
       (executable: %s)\n\
       Runtime state would pollute the repo. Use a workspace root instead:\n\
       \  --base-path $MASC_BASE_PATH    (recommended)\n\
       \  --base-path /path/to/workspace (explicit workspace root)\n\
       Or start via: sb mcp masc start\n"
      base_path abs_exe;
    exit 1
  end

let run_cmd host port base_path =
  Printexc.record_backtrace true;
  let raw_base_path = String.trim base_path in
  let normalized_base_path =
    Env_config.normalize_masc_base_path_input base_path
  in
  let resolution_source =
    match Sys.getenv_opt "MASC_BASE_PATH_RESOLUTION_SOURCE" with
    | Some source when String.trim source <> "" -> String.trim source
    | _ ->
        let inherited_env_matches =
          match Sys.getenv_opt "MASC_BASE_PATH" with
          | Some existing ->
              String.equal
                (Env_config.normalize_masc_base_path_input existing)
                normalized_base_path
          | None -> false
        in
        if inherited_env_matches then
          "explicit_env"
        else
          let default_path =
            Env_config.normalize_masc_base_path_input (default_base_path ())
          in
          if String.equal default_path normalized_base_path then
            implicit_base_path_resolution_source ()
          else
            "explicit_cli"
  in
  let stripped_base_path =
    Env_config.strip_path_trailing_slashes (String.trim base_path)
  in
  guard_self_repo_base_path normalized_base_path;
  if String.equal resolution_source "implicit_base_path" then begin
    Printf.eprintf
      "[FATAL] Server refused to start with an implicit base path.\n\
       Resolution source: %s\n\
       Resolved path: %s\n\n\
       Start the server with an explicit base path:\n\
       \  --base-path /path/to/workspace     (CLI flag)\n\
       \  MASC_BASE_PATH=/path/to/workspace  (environment variable)\n\n\
       Use a workspace root, not the repository checkout or $HOME directly.\n"
      resolution_source normalized_base_path;
    exit 1
  end;
  let masc_dir = Filename.concat normalized_base_path Common.masc_dirname in
  Fs_compat.mkdir_p masc_dir;
  acquire_pid_lock port;
  acquire_base_path_lock normalized_base_path;
  Log.init_from_env ();
  (* Decouple console mirror writes from the Eio domain before any keeper
     boots: with fd 2 on a pty, a full pty buffer (scrollback/copy-mode)
     blocks write(2) outside the scheduler and halts the whole fleet
     (#20684, 2026-06-10 live stall). *)
  Console_sink.start ();
  if stripped_base_path <> ""
     && String.equal (Filename.basename stripped_base_path) Common.masc_dirname
  then
    Log.Server.warn
      "Normalizing --base-path from %s to %s because runtime base paths must point at the workspace root, not the .masc directory."
      base_path normalized_base_path;
  Unix.putenv "MASC_BASE_PATH_INPUT" raw_base_path;
  Unix.putenv "MASC_BASE_PATH" normalized_base_path;
  Workspace_utils_backend_setup.cache_resolved_base_path normalized_base_path;
  Unix.putenv "MASC_BASE_PATH_RESOLUTION_SOURCE" resolution_source;
  (* Persist logs inside .masc/logs/ — colocated with state, not a sibling.
     Previous code wrote to base_path/logs/ which diverged from .masc/ when
     base_path differed from the repo checkout directory. *)
  let log_dir = Filename.concat masc_dir "logs" in
  Fs_compat.mkdir_p log_dir;
  (* Migration: move .jsonl files from old base_path/logs/ if they exist *)
  let old_log_dir = Filename.concat normalized_base_path "logs" in
  (if Sys.file_exists old_log_dir && Sys.is_directory old_log_dir then
     let files = try Sys.readdir old_log_dir with Sys_error _ -> [||] in
     Array.iter (fun fname ->
       if Filename.check_suffix fname ".jsonl" then begin
         let src = Filename.concat old_log_dir fname in
         let dst = Filename.concat log_dir fname in
         if not (Sys.file_exists dst) then
           (try Sys.rename src dst;
                Log.Server.info "log migration: moved %s -> .masc/logs/" fname
            with Sys_error _ -> ())
          end) files);
  Log.Ring.init_file_sink log_dir;
  Log.Ring.cleanup_old_files log_dir;
  Eio_main.run @@ fun env ->
  (* Initialize Mirage_crypto RNG - MUST be inside Eio_main.run for thread-local state *)
  Mirage_crypto_rng_unix.use_default ();

  (* Enable Eio-aware locking globally (single call replaces per-module enable_eio) *)
  Eio_guard.enable ();

  (* Set global clock for Time_compat (Eio-native timestamps).
     Dashboard_cache.now() reads from Time_compat directly. *)
  Time_compat.set_clock (Eio.Stdenv.clock env);

  (* Wire Runtime_events listener. After masc#18567 removed dead
     [Http_server_eio.start] (the only prior production caller), this
     would have been silently uninitialized. Idempotent-safe per
     [Masc_runtime_events] mli; consumed by Olly / custom callbacks
     to bracket agent turn spans ([emit_turn_start]/[emit_turn_end]). *)
  Masc_runtime_events.start_listener ();

  (* Signal handlers do the minimum async-signal-safe work: mark the sticky
     global flag so any fiber that observes [Eio.Cancel.Cancelled] before the
     watcher fiber wakes up can still classify itself as a graceful drop
     ([Keeper_registry_types_failure.fiber_drop_cause]: [Graceful_shutdown]),
     then enqueue the signal name for the Eio watcher fiber to consume.
     [Atomic.set]/[Atomic.get] are lock-free and signal-safe. *)
  let pending_shutdown_signal = Atomic.make None in
  let request_shutdown signal_name =
    Masc.Shutdown.mark_shutting_down ();
    if Option.is_none (Atomic.get pending_shutdown_signal) then
      Atomic.set pending_shutdown_signal (Some signal_name)
  in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle (fun _ -> request_shutdown "SIGTERM"));
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ -> request_shutdown "SIGINT"));

  let max_bind_retries = 5 in
  let rec try_start attempt =
    (try
      Eio.Switch.run @@ fun sw ->
      let clock = Eio.Stdenv.clock env in
      let rec await_shutdown_signal () =
        match Atomic.exchange pending_shutdown_signal None with
        | None ->
            Eio.Time.sleep clock 0.05;
            await_shutdown_signal ()
        | Some signal_name ->
            let shutdown_cfg = Masc.Shutdown.config_from_env () in
            let force_timeout = shutdown_cfg.force_timeout_s in
            let t_shutdown_start = Unix.gettimeofday () in
            Log.Server.info
              "[MASC] Received %s, shutting down gracefully (timeout=%.0fs)..."
              signal_name force_timeout;
            Eio.Fiber.fork_daemon ~sw (fun () ->
                Eio.Time.sleep clock force_timeout;
                let elapsed = Unix.gettimeofday () -. t_shutdown_start in
                Log.Server.error
                  "[MASC] Graceful shutdown timed out after %.1fs (limit=%.0fs), forcing exit."
                  elapsed force_timeout;
                exit 1);
            (* Phase 1: Notify SSE clients *)
            let t_phase = Unix.gettimeofday () in
            let shutdown_data =
              Printf.sprintf
                {|{"jsonrpc":"2.0","method":"notifications/shutdown","params":{"reason":"%s","message":"Server is shutting down, please reconnect"}}|}
                signal_name
            in
            Sse.broadcast (Yojson.Safe.from_string shutdown_data);
            Log.Server.info
              "[Shutdown] Phase 1/4 NOTIFY: sent to %d SSE clients (%.2fs) [active conn: %d, ws: %d]"
              (Sse.client_count ())
              (Unix.gettimeofday () -. t_phase)
              (Server_mcp_transport_http_sse.active_session_count ())
              (Server_mcp_transport_ws.session_count ());

            Eio.Time.sleep clock shutdown_cfg.notify_delay_s;
            (* Phase 2: Run shutdown hooks with cleanup timeout *)
            let t_phase = Unix.gettimeofday () in
            Log.Server.info "[Shutdown] Phase 2/4 HOOKS: starting (timeout=%.1fs)"
              shutdown_cfg.cleanup_timeout_s;
            (try
              Eio.Time.with_timeout_exn clock shutdown_cfg.cleanup_timeout_s
                (fun () -> Masc.Shutdown_hooks.run_all ())
            with
            | Eio.Time.Timeout ->
                Log.Server.warn
                  "[Shutdown] Phase 2/4 HOOKS: timeout after %.1fs, proceeding (total=%.1fs)"
                  shutdown_cfg.cleanup_timeout_s
                  (Unix.gettimeofday () -. t_shutdown_start)
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
                Log.Server.warn
                  "[Shutdown] Phase 2/4 HOOKS: failed after %.2fs: %s"
                  (Unix.gettimeofday () -. t_phase)
                  (Printexc.to_string exn));
            let now = Unix.gettimeofday () in
            Log.Server.info "[Shutdown] Phase 2/4 HOOKS: done (%.2fs, total=%.1fs) [active conn: %d, ws: %d]"
              (now -. t_phase)
              (now -. t_shutdown_start)
              (Server_mcp_transport_http_sse.active_session_count ())
              (Server_mcp_transport_ws.session_count ());
            (* Phase 3: Board flush with 2s timeout *)
            let t_phase = Unix.gettimeofday () in
            Log.Server.info "[Shutdown] Phase 3/4 BOARD: flush starting (timeout=2.0s)";
            (try
              Eio.Time.with_timeout_exn clock 2.0
                (fun () -> Board_dispatch.flush ())
            with
            | Eio.Time.Timeout ->
                Log.Server.warn
                  "[Shutdown] Phase 3/4 BOARD: timeout after 2.0s (total=%.1fs)"
                  (Unix.gettimeofday () -. t_shutdown_start)
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
                Log.Server.warn
                  "[Shutdown] Phase 3/4 BOARD: skipped after %.2fs: %s"
                  (Unix.gettimeofday () -. t_phase)
                  (Printexc.to_string exn));
            let now = Unix.gettimeofday () in
            Log.Server.info "[Shutdown] Phase 3/4 BOARD: done (%.2fs, total=%.1fs) [active conn: %d, ws: %d]"
              (now -. t_phase)
              (now -. t_shutdown_start)
              (Server_mcp_transport_http_sse.active_session_count ())
              (Server_mcp_transport_ws.session_count ());

            (* Phase 4: Return normally — Eio.Fiber.first will cancel
               run_server cleanly via Eio.Cancel.Cancelled. *)
            Log.Server.info
              "[Shutdown] Phase 4/4 CANCEL: server cancel (total=%.1fs) [active conn: %d, ws: %d]"
              (Unix.gettimeofday () -. t_shutdown_start)
              (Server_mcp_transport_http_sse.active_session_count ())
              (Server_mcp_transport_ws.session_count ());
            ()
            in
            Eio.Fiber.first
            (fun () -> run_server ~sw ~env ~host ~port ~base_path)
            await_shutdown_signal;
            (* Server stopped; close SSE connections after server is down. *)
            (try close_all_sse_connections ()
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
                Log.Server.warn "shutdown: SSE close error: %s"
                  (Printexc.to_string exn));
            Log.Server.info "MASC MCP: Server stopped, waiting for background fibers... [active conn: %d, ws: %d]"
            (Server_mcp_transport_http_sse.active_session_count ())
            (Server_mcp_transport_ws.session_count ())

    with
    | Eio.Cancel.Cancelled _ ->
        Log.Server.info "MASC MCP: Server cancelled, waiting for background fibers..."
    | Unix.Unix_error (Unix.EADDRINUSE, _, _) when attempt < max_bind_retries ->
        let delay = Float.min 30.0 (2.0 ** Float.of_int attempt) in
        Log.Server.warn "Port %d in use, retrying in %.0fs (attempt %d/%d)"
          port delay (attempt + 1) max_bind_retries;
        Time_compat.sleep delay;
        try_start (attempt + 1)
    | Unix.Unix_error (Unix.EADDRINUSE, _, _) ->
        Log.Server.error "[FATAL] Port %d is still in use after %d retries. Try: lsof -i :%d | grep LISTEN"
          port max_bind_retries port;
        exit 1
    | Unix.Unix_error (Unix.EACCES, _, _) ->
        Log.Server.error "[FATAL] Permission denied binding to port %d" port;
        exit 1
    | Out_of_memory ->
        Printf.eprintf "[FATAL] Out_of_memory\n%!";
        exit 1
    | Stack_overflow ->
        Printf.eprintf "[FATAL] Stack_overflow\n%!";
        exit 1
    | exn ->
        let bt = Printexc.get_backtrace () in
        Log.Server.error "[FATAL] Unhandled exception: %s" (Printexc.to_string exn);
        if bt <> "" then Log.Server.error "[FATAL] Backtrace:\n%s" bt;
        exit 1)
  in
  try_start 0;
  Log.Server.info "MASC MCP: Shutdown complete."

let run_cmd_exit host port base_path =
  run_cmd host port base_path;
  Cmd.Exit.ok

let login_cmd_exit base_path host port agent role client_env no_expiry
    as_json as_shell =
  let token_lifetime : Auth_login.token_lifetime =
    if no_expiry then Long_lived else With_expiry
  in
  match
    Auth_login.mint ~base_path ~host ~port ~agent_name:agent ~role
      ~token_env_var:client_env ~token_lifetime ()
  with
  | Error err ->
      Printf.eprintf "login failed: %s\n" (Masc_domain.masc_error_to_string err);
      1
  | Ok report ->
      let output =
        if as_shell then
          Auth_login.render_shell report
        else if as_json then
          Auth_login.to_yojson report |> Yojson.Safe.pretty_to_string
        else
          Auth_login.render_text report
      in
      print_endline output;
      0

let login_cmd =
  let doc =
    "Mint a local bearer token, persist its raw token file, and print \
     dashboard / MCP auth exports. Requires --client-env <VAR> to \
     name the env var your MCP client reads; the server itself is \
     client-agnostic."
  in
  let info = Cmd.info "login" ~doc in
  Cmd.v info
    Term.(
      const login_cmd_exit $ base_path $ host $ port $ login_agent
      $ login_role $ login_client_env $ login_no_expiry $ login_json
      $ login_shell)

let init_force =
  let doc = "Overwrite existing config files instead of skipping them" in
  Arg.(value & flag & info ["force"] ~doc)

type init_tally = { written : int; skipped : int; failed : int }

let seed_one ~target_root ~force tally rel =
  match Embedded_config.read rel with
  | None ->
    Printf.eprintf "init: missing embedded asset: %s\n" rel;
    { tally with failed = tally.failed + 1 }
  | Some content ->
    let dest = Filename.concat target_root rel in
    Fs_compat.mkdir_p (Filename.dirname dest);
    if Fs_compat.file_exists dest && not force then begin
      Printf.printf "skip   %s (exists, --force to overwrite)\n" dest;
      { tally with skipped = tally.skipped + 1 }
    end else
      try
        Fs_compat.save_file dest content;
        Printf.printf "wrote  %s (%d bytes)\n" dest (String.length content);
        { tally with written = tally.written + 1 }
      with Sys_error msg ->
        Printf.eprintf "init: %s: %s\n" dest msg;
        { tally with failed = tally.failed + 1 }

let init_cmd_exit base_path force =
  let base_path = Env_config.normalize_masc_base_path_input base_path in
  let target_root = Filename.concat (Filename.concat base_path ".masc") "config" in
  Fs_compat.mkdir_p target_root;
  let result =
    List.fold_left
      (seed_one ~target_root ~force)
      { written = 0; skipped = 0; failed = 0 }
      Embedded_config.file_list
  in
  Printf.printf "init: %d written, %d skipped, %d failed (root=%s)\n"
    result.written result.skipped result.failed target_root;
  if result.failed > 0 then 1 else 0

let init_cmd =
  let doc = "Seed default .masc/config/ from binary-embedded assets" in
  let info = Cmd.info "init" ~doc in
  Cmd.v info Term.(const init_cmd_exit $ base_path $ init_force)

let cmd =
  let doc = "MASC MCP Server and operator diagnostics" in
  let info = Cmd.info "masc" ~version:Masc.Version.version ~doc in
  Cmd.group ~default:Term.(const run_cmd_exit $ host $ port $ base_path)
    info [ init_cmd; login_cmd ]

let () = exit (Cmd.eval' cmd)
