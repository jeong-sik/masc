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
module Mcp_session = Masc_mcp.Mcp_session
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
module Tool_audit = Masc_mcp.Tool_audit
module Graphql_api = Masc_mcp.Graphql_api
module Types = Types
module Tempo = Masc_mcp.Tempo
module Auth = Masc_mcp.Auth
module Board = Masc_mcp.Board
module Board_dispatch = Masc_mcp.Board_dispatch
module Board_listener = Masc_mcp.Board_listener
module Council = Council
module Task_dispatch = Masc_mcp.Task_dispatch
module Http_negotiation = Masc_mcp.Mcp_protocol.Http_negotiation
module Progress = Masc_mcp.Progress
module Sse = Masc_mcp.Sse
module Safe_ops = Safe_ops
module Tool_mdal = Masc_mcp.Tool_mdal
module Tool_board = Masc_mcp.Tool_board
module Mdal = Masc_mcp.Mdal
module Server_command_plane_http = Masc_mcp.Server_command_plane_http
module Server_mcp_transport_http = Masc_mcp.Server_mcp_transport_http


(* ============================================ *)
(* Extracted modules (lib/)                      *)
(* ============================================ *)
include Masc_mcp.Server_utils
include Masc_mcp.Server_auth
include Masc_mcp.Server_tts_proxy
include Masc_mcp.Server_dashboard_http
module Server_h2_gateway = Masc_mcp.Server_h2_gateway
module Server_runtime_bootstrap = Masc_mcp.Server_runtime_bootstrap

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
  fun _client_addr gluten_reqd ->
    let reqd = gluten_reqd.Gluten.Reqd.reqd in
    let request = Httpun.Reqd.request reqd in
    try
      let path = Http.Request.path request in
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
          (* WebSocket upgrade — opt-in via MASC_WS_ENABLED=1 *)
          let ws_enabled = match Sys.getenv_opt "MASC_WS_ENABLED" with
            | Some "1" | Some "true" -> true
            | _ -> false
          in
          if ws_enabled then begin
            let on_message ws_session_id body_str =
              match (!Masc_mcp.Server_auth.server_state,
                     Eio_context.get_switch_opt (),
                     Eio_context.get_clock_opt ()) with
              | Some state, Some sw, Some clock ->
                Eio.Fiber.fork ~sw (fun () ->
                  try
                    let response_json =
                      Mcp_eio.handle_request ~clock ~sw
                        ~mcp_session_id:ws_session_id
                        state body_str
                    in
                    let response_str = Yojson.Safe.to_string response_json in
                    if response_str <> "null" then
                      ignore (Masc_mcp.Server_mcp_transport_ws.send_to_session
                        ws_session_id response_str)
                  with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn ->
                    Log.Server.warn "WS dispatch error %s: %s"
                      ws_session_id (Printexc.to_string exn))
              | _ ->
                Log.Server.warn "WS: server not ready for dispatch"
            in
            match Masc_mcp.Server_mcp_transport_ws.upgrade_connection
              ~on_message reqd with
            | Ok () -> ()
            | Error msg ->
              let body = Printf.sprintf {|{"error":"ws_upgrade_failed","message":"%s"}|} msg in
              let headers = Httpun.Headers.of_list [
                ("content-type", "application/json");
                ("content-length", string_of_int (String.length body));
              ] in
              let response = Httpun.Response.create ~headers `Bad_request in
              Httpun.Reqd.respond_with_string reqd response body
          end else begin
            let body = {|{"error":"websocket_disabled","message":"Set MASC_WS_ENABLED=1 to enable"}|} in
            let headers = Httpun.Headers.of_list [
              ("content-type", "application/json");
              ("content-length", string_of_int (String.length body));
            ] in
            let response = Httpun.Response.create ~headers `Not_found in
            Httpun.Reqd.respond_with_string reqd response body
          end
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
        | `DELETE, "/mcp" -> handle_delete_mcp request reqd
        | `DELETE, "/mcp/managed" ->
            handle_delete_mcp ~profile:Mcp_eio.Managed_agent request reqd
        | `DELETE, "/mcp/operator" ->
            handle_delete_mcp ~profile:Mcp_eio.Operator_remote request reqd
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
let run_server ~sw ~env ~host ~port ~base_path =
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
  Arg.(value & opt int 8935 & info ["p"; "port"] ~docv:"PORT" ~doc)

let host =
  let default =
    match trim_opt (Sys.getenv_opt "MASC_HOST") with
    | Some value -> value
    | None -> "127.0.0.1"
  in
  let doc =
    "Host/IP to bind. Defaults to loopback (`127.0.0.1`). Use `0.0.0.0` or `::` only when you also enable room auth with `require_token=true`."
  in
  Arg.(value & opt string default & info ["host"] ~docv:"HOST" ~doc)

let base_path =
  let doc = "Base path for MASC data (.masc folder location)" in
  Arg.(value & opt string (default_base_path ()) & info ["base-path"] ~docv:"PATH" ~doc)

(** Graceful shutdown exception *)
exception Shutdown

let run_cmd host port base_path =
  Eio_main.run @@ fun env ->
  (* Initialize Mirage_crypto RNG - MUST be inside Eio_main.run for thread-local state *)
  Mirage_crypto_rng_unix.use_default ();

  (* Enable Eio-aware locking in modules with dual-mode mutex guards *)
  Masc_mcp.Prometheus.enable_eio ();
  Masc_mcp.Chain_telemetry.enable_eio ();
  Masc_mcp.Generational_metrics.enable_eio ();
  Masc_mcp.Dashboard_cache.enable_eio ~clock:(Eio.Stdenv.clock env) ();

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
      Masc_mcp.Dashboard_cache.set_sw sw;
      let clock = Eio.Stdenv.clock env in
      let rec await_shutdown_signal () =
        match Atomic.exchange pending_shutdown_signal None with
        | None ->
            Eio.Time.sleep clock 0.05;
            await_shutdown_signal ()
        | Some signal_name ->
            Log.Server.info
              "[MASC] Received %s, shutting down gracefully..."
              signal_name;
            Eio.Fiber.fork_daemon ~sw (fun () ->
                Eio.Time.sleep clock 5.0;
                Log.Server.error
                  "[MASC] Graceful shutdown timed out after 5s, forcing exit.";
                exit 1);
            let shutdown_data =
              Printf.sprintf
                {|{"jsonrpc":"2.0","method":"notifications/shutdown","params":{"reason":"%s","message":"Server is shutting down, please reconnect"}}|}
                signal_name
            in
            Sse.broadcast (Yojson.Safe.from_string shutdown_data);
            Log.Server.info
              "[MASC] Sent shutdown notification to %d SSE clients"
              (Sse.client_count ());
            Eio.Time.sleep clock 0.2;
            Masc_mcp.Shutdown_hooks.run_all ();
            (try Board_dispatch.flush ()
             with _ ->
               Log.Server.warn
                 "[Shutdown] Board flush skipped (not initialized)");
            close_all_sse_connections ();
            Eio.Time.sleep clock 0.2;
            raise Shutdown
      in
      Eio.Fiber.first
        (fun () -> run_server ~sw ~env ~host ~port ~base_path)
        await_shutdown_signal
    with
    | Shutdown ->
        Log.Server.info "MASC MCP: Shutdown complete."
    | Eio.Cancel.Cancelled _ ->
        Log.Server.info "MASC MCP: Shutdown complete."
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
        exit 1)
  in
  try_start 0

let cmd =
  let doc = "MASC MCP Server" in
  let info = Cmd.info "masc-mcp" ~version:Masc_mcp.Version.version ~doc in
  Cmd.v info Term.(const run_cmd $ host $ port $ base_path)

let () = exit (Cmd.eval cmd)
