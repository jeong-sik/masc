(** MASC MCP Server - Eio Native Entry Point
    MCP Streamable HTTP Transport with Eio concurrency (OCaml 5.x)

    Uses h2-eio for HTTP/2 with unlimited SSE streams per connection.
    HTTP/2 multiplexing eliminates browser's 6-connection-per-domain limit.
*)

[@@@warning "-32-69"]  (* Suppress unused values/fields during migration *)

open Cmdliner

(** Module aliases *)
module Http = Masc_mcp.Http_server_eio
module Http_h2 = Masc_mcp.Http_server_h2
module Mcp_server = Masc_mcp.Mcp_server
module Mcp_eio = Masc_mcp.Mcp_server_eio
module Room = Masc_mcp.Room
module Room_utils = Room_utils
module Tool_keeper = Masc_mcp.Tool_keeper
module Keeper_types = Masc_mcp.Keeper_types
module Keeper_memory = Masc_mcp.Keeper_memory
module Keeper_execution = Masc_mcp.Keeper_execution
module Keeper_runtime = Masc_mcp.Keeper_runtime
module Tool_operator = Masc_mcp.Tool_operator
module Operator_control = Masc_mcp.Operator_control
module Command_plane_v2 = Masc_mcp.Command_plane_v2
module Dashboard_execution = Masc_mcp.Dashboard_execution
module Dashboard_mission = Masc_mcp.Dashboard_mission
module Dashboard_proof = Masc_mcp.Dashboard_proof
module Dashboard_mission_briefing = Masc_mcp.Dashboard_mission_briefing
module Build_identity = Masc_mcp.Build_identity
module Graphql_api = Masc_mcp.Graphql_api
module Types = Types
module Tempo = Masc_mcp.Tempo
module Auth = Masc_mcp.Auth
module Board = Masc_mcp.Board
module Board_dispatch = Masc_mcp.Board_dispatch
module Task_dispatch = Masc_mcp.Task_dispatch
module Http_negotiation = Mcp_transport_protocol.Http_negotiation
module Progress = Masc_mcp.Progress
module Sse = Masc_mcp.Sse
module Safe_ops = Safe_ops
module Tool_board = Masc_mcp.Tool_board
module Server_command_plane_http = Masc_mcp.Server_command_plane_http
module Server_mcp_transport_http = Masc_mcp.Server_mcp_transport_http


(* ============================================ *)
(* Extracted modules (lib/)                      *)
(* ============================================ *)
include Masc_mcp.Server_utils
include Masc_mcp.Server_auth
include Masc_mcp.Server_voice_config
include Masc_mcp.Server_dashboard_http
module Server_h2_gateway = Masc_mcp.Server_h2_gateway
module Server_runtime_bootstrap = Masc_mcp.Server_runtime_bootstrap
module Server_routes_http_runtime = Masc_mcp.Server_routes_http_runtime
module Server_openai_compat = Masc_mcp.Server_openai_compat
module Server_startup_takeover = Masc_mcp.Server_startup_takeover

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

module Server_routes_http = Masc_mcp.Server_routes_http

open Server_routes_http

(** Extended router to handle OPTIONS *)
let make_extended_handler routes =
  fun client_addr gluten_reqd ->
    let reqd = gluten_reqd.Gluten.Reqd.reqd in
    let request = Httpun.Reqd.request reqd in
    (* Rate limiting: enforce before any auth or routing.
       Health-check endpoints are exempt so load-balancer probes never block. *)
    let path = Http.Request.path request in
    let skip_rate_limit =
      String.equal path "/health"
      || String.equal path "/health/live"
      || String.equal path "/health/ready"
    in
    let rl_key = Masc_mcp.Rate_limit.key_of_sockaddr client_addr in
    if (not skip_rate_limit) && not (Masc_mcp.Rate_limit.check_global ~key:rl_key) then
      let body = Masc_mcp.Rate_limit.too_many_requests_body () in
      let rl_headers = Masc_mcp.Rate_limit.headers_global ~key:rl_key in
      let headers = Httpun.Headers.of_list (
        ("content-type", "application/json") ::
        ("content-length", string_of_int (String.length body)) ::
        rl_headers
      ) in
      Httpun.Reqd.respond_with_string reqd
        (Httpun.Response.create ~headers `Too_many_requests) body
    else
    try
      let is_mcp_like =
        String.equal path "/mcp"
        || String.equal path "/mcp/managed"
        || String.equal path "/mcp/operator"
        || String.equal path "/sse"
        || String.equal path "/messages"
      in
      let session_id_for_version = get_session_id_any request in
      let protocol_version =
        get_protocol_version_for_session ?session_id:session_id_for_version request
      in
      let origin = get_origin request in
      if is_mcp_like && not (validate_origin request) then
        let body = json_rpc_error (-32600) "Invalid origin" in
        let headers = Httpun.Headers.of_list (
          ("content-length", string_of_int (String.length body))
          :: json_headers "-" protocol_version origin
        ) in
        let response = Httpun.Response.create ~headers `Forbidden in
        Httpun.Reqd.respond_with_string reqd response body
      else if is_mcp_like && request.meth <> `OPTIONS &&
              not (is_valid_protocol_version protocol_version) then
        let body = json_rpc_error (-32600) "Unsupported protocol version" in
        let headers = Httpun.Headers.of_list (
          ("content-length", string_of_int (String.length body))
          :: json_headers "-" protocol_version origin
        ) in
        let response = Httpun.Response.create ~headers `Bad_request in
        Httpun.Reqd.respond_with_string reqd response body
      else
        match request.meth, path with
        | `OPTIONS, _ -> options_handler request reqd
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
          Httpun.Reqd.respond_with_string reqd response body
        | `POST, "/webrtc/offer" when Masc_mcp.Server_webrtc_transport.is_enabled () ->
          Http.Request.read_body_async reqd (fun body ->
            match Masc_mcp.Server_webrtc_transport.handle_offer_request body with
            | Ok json -> Http.Response.json json reqd
            | Error msg ->
              Http.Response.json ~status:`Bad_request
                (Printf.sprintf {|{"error":"%s"}|} msg) reqd)
        | `POST, "/webrtc/answer" when Masc_mcp.Server_webrtc_transport.is_enabled () ->
          Http.Request.read_body_async reqd (fun body ->
            match Masc_mcp.Server_webrtc_transport.handle_answer_request body with
            | Ok json -> Http.Response.json json reqd
            | Error msg ->
              Http.Response.json ~status:`Bad_request
                (Printf.sprintf {|{"error":"%s"}|} msg) reqd)
        | `POST, "/v1/chat/completions" when Server_openai_compat.is_enabled () ->
          Http.Request.read_body_async reqd (fun body ->
            match !server_state with
            | None ->
              let origin = get_origin request in
              Http.Response.json ~status:`Internal_server_error
                ~extra_headers:(cors_headers origin)
                (Server_openai_compat.error_response
                   ~status:"server_error" ~message:"Server not initialized")
                reqd
            | Some state ->
              let config = state.Mcp_server.room_config in
              let sw = Eio_context.get_switch () in
              let clock = Eio_context.get_clock () in
              let (status, resp_body) =
                Server_openai_compat.handle_chat_completions
                  ~config ~sw ~clock body
              in
              let origin = get_origin request in
              Http.Response.json ~status
                ~extra_headers:(cors_headers origin)
                resp_body reqd)
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
        | `GET, p
          when String.length p > 25
               && String.sub p 0 25 = "/api/v1/governance/cases/" ->
            (match !server_state with
             | None -> Http.Response.json {|{"error":"not initialized"}|} reqd
             | Some state ->
                 let case_id = String.sub p 25 (String.length p - 25) in
                 let base_path = state.Mcp_server.room_config.base_path in
                 let (status, json) = governance_case_detail_json ~base_path ~case_id in
                 Http.Response.json ~status (Yojson.Safe.to_string json) reqd)
        | `GET, p when String.length p > 14 && String.sub p 0 14 = "/api/v1/board/" ->
            let post_id = String.sub p 14 (String.length p - 14) in
            let format = Option.value ~default:"nested" (query_param request "format") in
            let (status, body) = board_post_detail_json ~response_format:format ~post_id in
            Http.Response.json ~status body reqd
        | _ -> Http.Router.dispatch routes request reqd
    with exn ->
      let msg = Printexc.to_string exn in
      Http.Response.internal_error msg reqd

(** Main server loop *)
let run_server ~sw:_ ~env ~host ~port ~base_path =
  (* Use a dedicated sub-switch so that ALL fibers spawned by
     Server_runtime_bootstrap (background maintenance, keeper loops,
     dashboard refresh, etc.) are children of this switch.  When
     Eio.Fiber.first cancels the run_server fiber on SIGTERM, the
     sub-switch is cancelled too, which propagates Cancel to every
     child fiber — preventing the 10s force-exit timeout. *)
  Eio.Switch.run @@ fun server_sw ->
  try
    Server_runtime_bootstrap.run ~sw:server_sw ~env ~host ~port ~base_path ~make_routes
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
    "Host/IP to bind. Defaults to loopback (`127.0.0.1`). Use `0.0.0.0` or `::` only when you also enable room auth with `require_token=true`."
  in
  Arg.(value & opt string default & info ["host"] ~docv:"HOST" ~doc)

let base_path =
  let doc = "Base path for MASC data (.masc folder location)" in
  Arg.(value & opt string (default_base_path ()) & info ["base-path"] ~docv:"PATH" ~doc)

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

let run_cmd host port base_path =
  Printexc.record_backtrace true;
  acquire_pid_lock port;
  Log.init_from_env ();
  Unix.putenv "MASC_BASE_PATH" base_path;
  (* Persist logs inside .masc/logs/ — colocated with state, not a sibling.
     Previous code wrote to base_path/logs/ which diverged from .masc/ when
     base_path differed from the repo checkout directory. *)
  let masc_dir = Filename.concat base_path ".masc" in
  let log_dir = Filename.concat masc_dir "logs" in
  Fs_compat.mkdir_p masc_dir;
  Fs_compat.mkdir_p log_dir;
  (* Migration: move .jsonl files from old base_path/logs/ if they exist *)
  let old_log_dir = Filename.concat base_path "logs" in
  (if Sys.file_exists old_log_dir && Sys.is_directory old_log_dir then
     let files = try Sys.readdir old_log_dir with Sys_error _ -> [||] in
     Array.iter (fun fname ->
       if Filename.check_suffix fname ".jsonl" then begin
         let src = Filename.concat old_log_dir fname in
         let dst = Filename.concat log_dir fname in
         if not (Sys.file_exists dst) then
           (try Sys.rename src dst;
                Log.info "log migration: moved %s -> .masc/logs/" fname
            with Sys_error _ -> ())
       end) files);
  Log.Ring.init_file_sink log_dir;
  Log.Ring.cleanup_old_files log_dir;
  Eio_main.run @@ fun env ->
  (* Initialize Mirage_crypto RNG - MUST be inside Eio_main.run for thread-local state *)
  Mirage_crypto_rng_unix.use_default ();

  (* Enable Eio-aware locking globally (single call replaces per-module enable_eio) *)
  Eio_guard.enable ();
  Masc_mcp.Transport_metrics.init ();
  Masc_mcp.Dashboard_cache.set_clock (Eio.Stdenv.clock env);

  (* Set global clock for Time_compat (Eio-native timestamps) *)
  Time_compat.set_clock (Eio.Stdenv.clock env);

  (* Initialize thread-safe token store for cancellation support *)
  Masc_mcp.Cancellation.TokenStore.init ();

  (* Signal handlers stay side-effect free. The Eio watcher fiber performs
     all shutdown work inside the event loop. *)
  let pending_shutdown_signal = Atomic.make None in
  let request_shutdown signal_name =
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
            let shutdown_cfg = Masc_mcp.Shutdown.config_from_env () in
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
              (Masc_mcp.Server_mcp_transport_http_sse.active_session_count ())
              (Masc_mcp.Server_mcp_transport_ws.session_count ());

            Eio.Time.sleep clock shutdown_cfg.notify_delay_s;
            (* Phase 2: Run shutdown hooks with cleanup timeout *)
            let t_phase = Unix.gettimeofday () in
            Log.Server.info "[Shutdown] Phase 2/4 HOOKS: starting (timeout=%.1fs)"
              shutdown_cfg.cleanup_timeout_s;
            (try
              Eio.Time.with_timeout_exn clock shutdown_cfg.cleanup_timeout_s
                (fun () -> Masc_mcp.Shutdown_hooks.run_all ())
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
              (Masc_mcp.Server_mcp_transport_http_sse.active_session_count ())
              (Masc_mcp.Server_mcp_transport_ws.session_count ());
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
              (Masc_mcp.Server_mcp_transport_http_sse.active_session_count ())
              (Masc_mcp.Server_mcp_transport_ws.session_count ());

            (* Phase 4: Return normally — Eio.Fiber.first will cancel
               run_server cleanly via Eio.Cancel.Cancelled. *)
            Log.Server.info
              "[Shutdown] Phase 4/4 CANCEL: server cancel (total=%.1fs) [active conn: %d, ws: %d]"
              (Unix.gettimeofday () -. t_shutdown_start)
              (Masc_mcp.Server_mcp_transport_http_sse.active_session_count ())
              (Masc_mcp.Server_mcp_transport_ws.session_count ());
            ()
            in
            Eio.Fiber.first
            (fun () -> run_server ~sw ~env ~host ~port ~base_path)
            await_shutdown_signal;
            (* Server stopped; close SSE connections after server is down. *)
            (try close_all_sse_connections ()
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | _ -> ());
            Log.Server.info "MASC MCP: Server stopped, waiting for background fibers... [active conn: %d, ws: %d]"
            (Masc_mcp.Server_mcp_transport_http_sse.active_session_count ())
            (Masc_mcp.Server_mcp_transport_ws.session_count ())

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

let cmd =
  let doc = "MASC MCP Server" in
  let info = Cmd.info "masc-mcp" ~version:Masc_mcp.Version.version ~doc in
  Cmd.v info Term.(const run_cmd $ host $ port $ base_path)

let () = exit (Cmd.eval cmd)
