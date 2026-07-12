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

(** Returns true if the request failed origin or protocol-version
    validation and the corresponding error response was sent on [reqd].
    Caller should short-circuit further handling in that case. *)
let try_mcp_validation_block
    ~request_authority
    ~request
    ~protocol_version
    ~origin
    reqd
  =
  let is_mcp_transport = is_mcp_transport_request request in
  if
    is_mcp_transport
    && not (validate_origin ~request_authority request)
  then begin
    let body = json_rpc_error Masc.Mcp_error_code.Invalid_request "Invalid origin" in
    let headers =
      Httpun.Headers.of_list
        ([ ("content-length", string_of_int (String.length body))
         ; ("content-type", "application/json")
         ; ("vary", "Origin")
         ]
         @ mcp_headers "-" protocol_version)
    in
    let response = Httpun.Response.create ~headers `Forbidden in
    safe_reqd_respond reqd response body;
    true
  end
  else if is_mcp_transport && request.Httpun.Request.meth <> `OPTIONS &&
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


(** Method/path dispatcher for MCP-validated requests. Caller is
    responsible for rate limiting and origin/protocol-version checks
    before invoking this function.

    [GET /ws] (same-origin WebSocket upgrade + discovery) is owned by
    the route table ([Server_routes_http_routes_frontend] via
    [Http.Router.ws_get]) and reached through
    [Http.Router.dispatch ~upgrade] below.  RFC-0281 consolidated the
    previously-duplicated main_eio upgrade/discovery handlers into the
    router so [/ws] has a single owner that actually drives the
    connection. *)
let dispatch_route ~router ~request ~path ~upgrade reqd =
  match request.Httpun.Request.meth, path with
  | `OPTIONS, _ -> options_handler request reqd
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
  (* Board reads/reactions are owned by the typed route table: exact routes
     ([/api/v1/board/reactions], [/catalog]) win over the board prefix route,
     and the prefix route resolves the bearer-bound reaction actor itself. *)
  | _ -> Http.Router.dispatch router ~upgrade request reqd

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

let respond_request_authority_bad_request ~error_code ~message reqd =
  Http.Response.json_value
    ~status:`Bad_request
    (`Assoc [ "error_code", `String error_code; "error", `String message ])
    reqd
;;

(** Extended router to handle OPTIONS *)
let make_extended_handler routes =
  fun client_addr gluten_reqd ->
    let reqd = gluten_reqd.Gluten.Reqd.reqd in
    (* Gluten upgrade capability — only available here at the connection
       boundary.  Threaded to [Http.Router.dispatch] so WebSocket routes
       ([Http.Router.ws_get]) can drive the post-101 connection.
       RFC-0281. *)
    let upgrade = gluten_reqd.Gluten.Reqd.upgrade in
    let request = Httpun.Reqd.request reqd in
    match Server_request_authority.classify_http1_request request with
    | Server_request_authority.Missing ->
      respond_request_authority_bad_request
        ~error_code:"request_authority_missing"
        ~message:"request is missing its Host authority"
        reqd
    | Server_request_authority.Multiple ->
      respond_request_authority_bad_request
        ~error_code:"request_authority_multiple"
        ~message:"request contains more than one Host field"
        reqd
    | Server_request_authority.Malformed ->
      respond_request_authority_bad_request
        ~error_code:"request_authority_malformed"
        ~message:"request Host authority is malformed"
        reqd
    | Server_request_authority.Single request_authority ->
      Server_request_authority.with_current request_authority (fun () ->
        (* Authority admission precedes rate limiting, auth, and routing so no
           credential I/O or URL projection can observe ambiguous Host input. *)
        let path = Http.Request.path request in
        if try_rate_limit_block ~path ~client_addr ~request reqd
        then ()
        else
          try
            let session_id_for_version = get_session_id_any request in
            let protocol_version =
              get_protocol_version_for_session
                ?session_id:session_id_for_version
                request
            in
            let origin = get_origin request in
            if
              try_mcp_validation_block
                ~request_authority
                ~request
                ~protocol_version
                ~origin
                reqd
            then ()
            else dispatch_route ~router:routes ~request ~path ~upgrade reqd
          with
          (* Re-raise cancellation so Eio structured concurrency propagates
             cleanly.  Previously the catch-all swallowed Cancelled and tried
             to write a 500 response; that masks shutdown signals and
             interferes with per-connection switch cleanup. *)
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn ->
            let msg = Printexc.to_string exn in
            (match Http.Late_response.classify_write_failure exn with
             | Some failure_msg ->
               log_late_response_failure
                 ~context:"main_eio request handler"
                 failure_msg
             | None -> try_internal_error_response reqd msg))

(** Main server loop *)
let run_server ~sw ~env ~host ~port ~base_path =
  (* Use the parent switch directly so that ALL fibers spawned by
     Server_runtime_bootstrap (background maintenance, keeper loops,
     dashboard refresh, etc.) are children of this switch.  Graceful
     shutdown explicitly fails this switch after the signal handler
     finishes its phases (see [Graceful_shutdown] below); failing the
     switch propagates cancellation to every child fiber, preventing
     the 10s force-exit timeout. *)
  try
    Server_runtime_bootstrap.run ~sw ~env ~host ~port ~base_path ~make_routes
      ~make_request_handler:make_extended_handler
      ~make_h2_request_handler:Server_h2_gateway.make_request_handler
      ~make_h2_error_handler:Server_h2_gateway.make_error_handler
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Server.error
      "[main] keeper bootstrap failed; refusing to continue without keepers: %s"
      (Printexc.to_string exn);
    raise exn

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

let run_base_path =
  let doc =
    "Workspace root for MASC data. Runtime state lives under <base-path>/.masc; do not pass the .masc directory itself."
  in
  Arg.(value & opt (some string) None & info ["base-path"] ~docv:"PATH" ~doc)

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

(** Graceful shutdown exception.

    Raised from the main [Switch.run] fiber after shutdown phases complete.
    This causes [Eio.Switch.run] to fail the switch, which cancels every
    remaining background fiber and waits for them to finish.  Returning
    normally would leave non-daemon background fibers running and make
    [Switch.run] wait forever. *)
exception Graceful_shutdown

type shutdown_signal =
  | Sigterm
  | Sigint

let shutdown_signal_name = function
  | Sigterm -> "SIGTERM"
  | Sigint -> "SIGINT"

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

let run_cmd host port cli_base_path =
  Printexc.record_backtrace true;
  let resolved_base_path =
    Server_base_path_guard.resolve_startup_base_path ~cli_base_path
      ~default_base_path ()
  in
  Server_base_path_guard.exit_on_violation
    (Server_base_path_guard.enforce resolved_base_path);
  let raw_base_path = resolved_base_path.raw_base_path in
  let normalized_base_path = resolved_base_path.normalized_base_path in
  let resolution_source =
    Server_base_path_guard.resolution_source_label
      resolved_base_path.resolution_source
  in
  let stripped_base_path =
    Env_config.strip_path_trailing_slashes (String.trim raw_base_path)
  in
  let masc_dir = Filename.concat normalized_base_path Common.masc_dirname in
  Fs_compat.mkdir_p masc_dir;
  acquire_pid_lock port;
  acquire_base_path_lock normalized_base_path;
  Log.init_from_env ();
  let shutdown_cfg =
    match Masc.Shutdown.config_from_env_result () with
    | Ok config -> config
    | Error error ->
        Log.Server.error "[FATAL] Invalid shutdown configuration: %s"
          (Masc.Shutdown.config_error_to_string error);
        exit 1
  in
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
      raw_base_path normalized_base_path;
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
  let shutdown_watchdog : Masc.Shutdown.watchdog option Atomic.t = Atomic.make None in
  let request_shutdown signal =
    Masc.Shutdown.mark_shutting_down ();
    if Option.is_none (Atomic.get pending_shutdown_signal) then
      Atomic.set pending_shutdown_signal (Some signal)
  in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle (fun _ -> request_shutdown Sigterm));
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ -> request_shutdown Sigint));

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
        | Some signal ->
            let force_timeout = shutdown_cfg.force_timeout_s in
            let t_shutdown_start = Unix.gettimeofday () in
            let signal_name = shutdown_signal_name signal in
            let watchdog =
              Masc.Shutdown.start_process_deadline_watchdog_or_exit
                ~timeout_s:force_timeout
            in
            Atomic.set shutdown_watchdog (Some watchdog);
            Log.Server.info
              "[MASC] Received %s, shutting down gracefully (timeout=%.0fs, hard_exit=%d)..."
              signal_name force_timeout Masc.Shutdown.process_deadline_exit_code;
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
            (fun () -> run_server ~sw ~env ~host ~port ~base_path:normalized_base_path)
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
            (Server_mcp_transport_ws.session_count ());
            (* Failing the switch cancels all remaining background fibers.
               Returning normally would leave non-daemon background loops
               running and make [Eio.Switch.run] wait forever. *)
            raise Graceful_shutdown

    with
    | Graceful_shutdown ->
        Log.Server.info "MASC MCP: Background fibers finished, shutdown complete."
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
  (match Atomic.get shutdown_watchdog with
   | None -> ()
   | Some watchdog ->
       (match Masc.Shutdown.disarm_deadline_watchdog watchdog with
        | Masc.Shutdown.Disarmed | Masc.Shutdown.Already_disarmed -> ()
        | Masc.Shutdown.Already_fired ->
            Masc.Shutdown.await_deadline_watchdog watchdog));
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

let start_cmd =
  let doc =
    "Start the MASC MCP server (HTTP/SSE). Same as running `masc` with no \
     subcommand; exposed as an explicit name for quick-start guides."
  in
  let info = Cmd.info "start" ~doc in
  Cmd.v info Term.(const run_cmd_exit $ host $ port $ run_base_path)

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
  (* [init] seeds the explicitly requested workspace; runtime resolution may
     honor [MASC_CONFIG_DIR], but bootstrap materialization must not. *)
  let target_root =
    Config_dir_resolver.base_path_config_root
      ~cwd:(Config_dir_resolver.current_working_dir ())
      base_path
  in
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

let runtime_config_path_for_base_path base_path =
  let base_path = Env_config.normalize_masc_base_path_input base_path in
  let config_root =
    Config_dir_resolver.base_path_config_root
      ~cwd:(Config_dir_resolver.current_working_dir ())
      base_path
  in
  Filename.concat config_root Config_dir_resolver.runtime_toml_filename

let runtime_default_id =
  let doc = "Concrete runtime id to write into [runtime].default" in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"RUNTIME_ID" ~doc)

let runtime_default_set_cmd_exit base_path runtime_id =
  let runtime_config_path = runtime_config_path_for_base_path base_path in
  match
    Runtime.set_runtime_default ~runtime_config_path ~runtime_id ()
  with
  | Ok () ->
      Printf.printf "set [runtime].default = \"%s\" in %s\n" runtime_id
        runtime_config_path;
      0
  | Error msg ->
      Printf.eprintf "runtime-default-set failed: %s\n" msg;
      1

let runtime_default_set_cmd =
  let doc =
    "Validate and update [runtime].default in runtime.toml using the runtime \
     config writer."
  in
  let info = Cmd.info "runtime-default-set" ~doc in
  Cmd.v info Term.(const runtime_default_set_cmd_exit $ base_path $ runtime_default_id)

let runtime_wizard_field ~field value =
  if String.exists (Char.equal '\000') value
  then Error (Printf.sprintf "runtime-wizard-catalog field %s contains a NUL byte" field)
  else Ok value

let runtime_wizard_fields fields =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (field, value) :: rest ->
        (match runtime_wizard_field ~field value with
         | Error _ as err -> err
         | Ok value -> loop (value :: acc) rest)
  in
  loop [] fields

let runtime_wizard_endpoint (provider : Runtime_schema.provider) =
  match provider.transport with
  | Runtime_schema.Http endpoint -> Ok endpoint
  | Runtime_schema.Cli _ ->
      Error
        (Printf.sprintf
           "provider %s uses a CLI transport; install wizard requires an HTTP endpoint"
           provider.id)

let runtime_wizard_credential_key (provider : Runtime_schema.provider) =
  match provider.credentials with
  | None -> Ok ""
  | Some (Runtime_schema.Env key) -> Ok key
  | Some (Runtime_schema.File _ | Runtime_schema.Inline _) ->
      Error
        (Printf.sprintf
           "provider %s uses a non-env credential; install wizard cannot write .env.local"
           provider.id)

let runtime_wizard_binding_for_provider (cfg : Runtime_schema.config)
    (provider : Runtime_schema.provider) =
  let bindings =
    List.filter
      (fun (binding : Runtime_schema.binding) ->
         String.equal binding.provider_id provider.id)
      cfg.bindings
  in
  match bindings with
  | [] -> Error (Printf.sprintf "provider %s has no concrete runtime binding" provider.id)
  | _ ->
      (match List.filter (fun (binding : Runtime_schema.binding) -> binding.wizard_default) bindings with
       | [ binding ] -> Ok binding
       | [] ->
           Error
             (Printf.sprintf
                "provider %s has no install wizard default binding; set wizard-default = true on exactly one [%s.<model>] binding"
                provider.id provider.id)
       | defaults ->
           Error
             (Printf.sprintf
                "provider %s has %d install wizard default bindings; set wizard-default = true on exactly one [%s.<model>] binding"
                provider.id
                (List.length defaults)
                provider.id))

let runtime_wizard_provider_record cfg (provider : Runtime_schema.provider) =
  match
    ( runtime_wizard_endpoint provider
    , runtime_wizard_credential_key provider
    , runtime_wizard_binding_for_provider cfg provider )
  with
  | Error msg, _, _ | _, Error msg, _ | _, _, Error msg -> Error msg
  | Ok endpoint, Ok credential_key, Ok binding ->
      let runtime_id = Runtime_schema.binding_key binding in
      runtime_wizard_fields
        [ "kind", "provider"
        ; "id", provider.id
        ; "display_name", provider.display_name
        ; "credential_key", credential_key
        ; "endpoint", endpoint
        ; "healthcheck_path", Option.value ~default:"" provider.healthcheck_path
        ; "runtime_id", runtime_id
        ]

let runtime_wizard_default_record (cfg : Runtime_schema.config) =
  match cfg.default_runtime_id with
  | None -> Ok None
  | Some runtime_id ->
      (match
         List.find_opt
           (fun (binding : Runtime_schema.binding) ->
              String.equal (Runtime_schema.binding_key binding) runtime_id)
           cfg.bindings
       with
       | Some binding ->
           (match
              runtime_wizard_fields
                [ "kind", "default-provider"; "id", binding.provider_id ]
            with
            | Error _ as err -> err
            | Ok record -> Ok (Some record))
       | None ->
           (match
              runtime_wizard_fields
                [ "kind", "default-runtime-missing"; "runtime_id", runtime_id ]
            with
            | Error _ as err -> err
            | Ok record -> Ok (Some record)))

let runtime_wizard_catalog_records (cfg : Runtime_schema.config) =
  let rec provider_records acc = function
    | [] -> Ok (List.rev acc)
    | provider :: rest ->
        (match runtime_wizard_provider_record cfg provider with
         | Error _ as err -> err
         | Ok record -> provider_records (record :: acc) rest)
  in
  match provider_records [] cfg.providers with
  | Error _ as err -> err
  | Ok records ->
      (match runtime_wizard_default_record cfg with
       | Error _ as err -> err
       | Ok None -> Ok records
       | Ok (Some default_record) -> Ok (records @ [ default_record ]))

let runtime_wizard_print_record fields =
  List.iter
    (fun field ->
       output_string stdout field;
       output_char stdout '\000')
    fields

let runtime_wizard_parse_errors errors =
  errors
  |> List.map (fun (err : Runtime_toml.parse_error) ->
    Printf.sprintf "%s: %s" err.path err.message)
  |> String.concat "; "

let runtime_wizard_catalog_cmd_exit base_path =
  let runtime_config_path = runtime_config_path_for_base_path base_path in
  match Runtime_toml.parse_file runtime_config_path with
  | Error errors ->
      Printf.eprintf "runtime-wizard-catalog failed: %s\n"
        (runtime_wizard_parse_errors errors);
      1
  | Ok cfg ->
      (match runtime_wizard_catalog_records cfg with
       | Error msg ->
           Printf.eprintf "runtime-wizard-catalog failed: %s\n" msg;
           1
       | Ok records ->
           List.iter runtime_wizard_print_record records;
           0)

let runtime_wizard_catalog_cmd =
  let doc =
    "Print the typed provider catalog used by the first-run install wizard."
  in
  let info = Cmd.info "runtime-wizard-catalog" ~doc in
  Cmd.v info Term.(const runtime_wizard_catalog_cmd_exit $ base_path)

let memory_os_keeper =
  let doc =
    "Only scan the given keeper id. Repeatable. When omitted, all existing \
     non-shared keeper fact stores are scanned."
  in
  Arg.(value & opt_all string [] & info ["keeper"] ~docv:"KEEPER" ~doc)

let memory_os_gc_json =
  let doc = "Emit machine-readable JSON instead of text output" in
  Arg.(value & flag & info ["json"] ~doc)

let memory_os_gc_dry_run_cmd_exit base_path keeper_ids as_json =
  let base_path = Env_config.normalize_masc_base_path_input base_path in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let report =
    Eio_main.run
    @@ fun env ->
    let now = Eio.Time.now (Eio.Stdenv.clock env) in
    match keeper_ids with
    | [] ->
      Masc.Keeper_memory_os_gc_dry_run_report.run_for_keepers_dir
        ~keepers_dir
        ~now
        ()
    | ids ->
      Masc.Keeper_memory_os_gc_dry_run_report.run_for_keepers_dir
        ~keepers_dir
        ~keeper_ids:ids
        ~now
        ()
  in
  if as_json
  then
    print_endline
      (Yojson.Safe.pretty_to_string
         (Masc.Keeper_memory_os_gc_dry_run_report.to_json report))
  else
    print_string (Masc.Keeper_memory_os_gc_dry_run_report.render_text report);
  if report.error_count > 0 then 1 else 0

let memory_os_gc_dry_run_cmd =
  let doc =
    "Run the Memory OS fact-store GC in dry-run mode and print the TTL/dedup \
     report without rewriting stores. The scan still takes each keeper fact-store \
     lock; contended stores are reported as per-keeper errors."
  in
  let info = Cmd.info "memory-os-gc-dry-run" ~doc in
  Cmd.v info
    Term.(
      const memory_os_gc_dry_run_cmd_exit $ base_path $ memory_os_keeper
      $ memory_os_gc_json)

let memory_os_sanity_sweep_cmd_exit base_path keeper_ids as_json =
  let base_path = Env_config.normalize_masc_base_path_input base_path in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let report =
    Eio_main.run
    @@ fun env ->
    let now = Eio.Time.now (Eio.Stdenv.clock env) in
    match keeper_ids with
    | [] ->
      Masc.Keeper_memory_os_sanity_sweep.run_for_keepers_dir
        ~keepers_dir
        ~now
        ()
    | ids ->
      Masc.Keeper_memory_os_sanity_sweep.run_for_keepers_dir
        ~keepers_dir
        ~keeper_ids:ids
        ~now
        ()
  in
  if as_json
  then
    print_endline
      (Yojson.Safe.pretty_to_string
         (Masc.Keeper_memory_os_sanity_sweep.to_json report))
  else print_string (Masc.Keeper_memory_os_sanity_sweep.render_text report);
  if report.error_count > 0 then 1 else 0

let memory_os_sanity_sweep_cmd =
  let doc =
    "Build a read-only Memory OS sanity review packet: typed current/expired \
     fact rows, duplicate claim identities, and deterministic GC preview. It \
     never rewrites stores and never infers obsolete facts from claim prose."
  in
  let info = Cmd.info "memory-os-sanity-sweep" ~doc in
  Cmd.v info
    Term.(
      const memory_os_sanity_sweep_cmd_exit $ base_path $ memory_os_keeper
      $ memory_os_gc_json)

let schedule_prune_cmd_exit base_path =
  let config = Workspace_utils.default_config base_path in
  match Schedule_service.prune config with
  | Error err ->
      prerr_endline (Schedule_service.service_error_to_string err);
      1
  | Ok (_, count) ->
      Printf.printf "Successfully pruned %d completed schedule(s).\n" count;
      0

let schedule_prune_cmd =
  let doc =
    "Prune completed (Succeeded/Failed/Rejected/Cancelled/Expired) schedules and associated executions/grants."
  in
  let info = Cmd.info "schedule-prune" ~doc in
  Cmd.v info Term.(const schedule_prune_cmd_exit $ base_path)

let setup_gc () =
  (* OCaml 5 defaults to a 2 MiB minor heap per active domain.  Sampling
     main_eio.exe showed heavy stop-the-world minor-GC pressure from JSON
     parsing and metric encoding, with many domains parked waiting for STW.
     Bumping the per-domain minor heap reduces the frequency of those
     parallel pauses.  We only override when the operator has not set
     OCAMLRUNPARAM so existing tuning instructions remain authoritative. *)
  match Sys.getenv_opt "OCAMLRUNPARAM" with
  | Some _ -> ()
  | None ->
      let gc = Gc.get () in
      let desired_minor_words = 4 * 1024 * 1024 in
      (* 4M words ~= 32 MiB on 64-bit *)
      if gc.minor_heap_size < desired_minor_words then
        Gc.set { gc with minor_heap_size = desired_minor_words }

let cmd =
  let doc = "MASC MCP Server and operator diagnostics" in
  let info = Cmd.info "masc" ~version:Masc.Version.version ~doc in
  Cmd.group ~default:Term.(const run_cmd_exit $ host $ port $ run_base_path)
    info
    [ init_cmd
    ; start_cmd
    ; login_cmd
    ; runtime_default_set_cmd
    ; runtime_wizard_catalog_cmd
    ; memory_os_gc_dry_run_cmd
    ; memory_os_sanity_sweep_cmd
    ; schedule_prune_cmd
    ]

let () =
  setup_gc ();
  exit (Cmd.eval' cmd)
