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
module Room_utils = Masc_mcp.Room_utils
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
module Types = Masc_mcp.Types
module Tempo = Masc_mcp.Tempo
module Auth = Masc_mcp.Auth
module Board = Masc_mcp.Board
module Board_dispatch = Masc_mcp.Board_dispatch
module Board_listener = Masc_mcp.Board_listener
module Council = Masc_mcp.Council
module Task_dispatch = Masc_mcp.Task_dispatch
module Http_negotiation = Masc_mcp.Mcp_protocol.Http_negotiation
module Progress = Masc_mcp.Progress
module Sse = Masc_mcp.Sse
module Safe_ops = Masc_mcp.Safe_ops
module Context_manager = Masc_mcp.Context_manager
module Llm_client = Masc_mcp.Llm_client
module Tool_perpetual = Masc_mcp.Tool_perpetual
module Tool_mdal = Masc_mcp.Tool_mdal
module Tool_board = Masc_mcp.Tool_board
module Process_eio = Masc_mcp.Process_eio
module Mdal = Masc_mcp.Mdal
module Server_command_plane_http = Masc_mcp.Server_command_plane_http
module Server_mcp_transport_http = Masc_mcp.Server_mcp_transport_http


(* ============================================ *)
(* Extracted modules (lib/)                      *)
(* ============================================ *)
include Masc_mcp.Server_utils
include Masc_mcp.Server_auth
include Masc_mcp.Server_tts_proxy
include Masc_mcp.Server_trpg_rest
include Masc_mcp.Server_dashboard_http
module Server_h2_gateway = Masc_mcp.Server_h2_gateway

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
        | `DELETE, "/mcp" -> handle_delete_mcp request reqd
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
          when String.length p > 32
               && String.length p >= 24 + 8
               && String.sub p 0 24 = "/api/v1/council/debates/"
               && String.ends_with ~suffix:"/summary" p ->
            (match !server_state with
             | None -> Http.Response.json {|{"error":"not initialized"}|} reqd
             | Some state ->
                 let prefix_len = 24 in
                 let suffix_len = 8 in
                 let debate_id_len = String.length p - prefix_len - suffix_len in
                 if debate_id_len <= 0 then
                   Http.Response.json ~status:`Bad_request {|{"error":"debate_id missing"}|} reqd
                 else
                   let debate_id = String.sub p prefix_len debate_id_len in
                   let base_path = state.Mcp_server.room_config.base_path in
                   let (status, json) = council_debate_summary_json ~base_path ~debate_id in
                   Http.Response.json ~status (Yojson.Safe.to_string json) reqd)
        | `GET, p
          when String.length p > 33
               && String.length p >= 25 + 8
               && String.sub p 0 25 = "/api/v1/council/sessions/"
               && String.ends_with ~suffix:"/summary" p ->
            (match !server_state with
             | None -> Http.Response.json {|{"error":"not initialized"}|} reqd
             | Some state ->
                 let prefix_len = 25 in
                 let suffix_len = 8 in
                 let session_id_len = String.length p - prefix_len - suffix_len in
                 if session_id_len <= 0 then
                   Http.Response.json ~status:`Bad_request {|{"error":"session_id missing"}|} reqd
                 else
                   let session_id = String.sub p prefix_len session_id_len in
                   let base_path = state.Mcp_server.room_config.base_path in
                   let (status, json) = council_session_summary_json ~base_path ~session_id in
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
  (* Extract components from Eio environment *)
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  let net = Eio.Stdenv.net env in
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let fs = Eio.Stdenv.fs env in

  (* Set net and clock references in Mcp_eio for async operations *)
  Mcp_eio.set_net net;
  Mcp_eio.set_clock clock;
  Masc_mcp.Eio_context.set_switch sw;
  Masc_mcp.Eio_context.set_net net;
  Masc_mcp.Eio_context.set_clock clock;
  Council.Thread_persist.set_eio_context ~clock
    ~https_connector:(Masc_mcp.Eio_context.get_https_connector ())
    net;
  Masc_mcp.Process_eio.init
    ~cwd_default:Eio.Path.(fs / base_path)
    ~proc_mgr ~clock;

  (* Create Caqti-compatible stdenv adapter
     Note: net type coercion from [Generic|Unix] to [Generic] is safe
     because Caqti only uses the generic network capabilities *)
  let caqti_env : Caqti_eio.stdenv = object
    method net = (net :> [`Generic] Eio.Net.ty Eio.Resource.t)
    method clock = clock
    method mono_clock = mono_clock
  end in

  Unix.putenv "MASC_BASE_PATH_INPUT" base_path;

  (* Initialize server state with Eio context *)
  let state = Mcp_eio.create_state_eio ~sw ~env:caqti_env ~proc_mgr ~fs ~clock ~net ~base_path in
  server_state := Some state;
  ignore (Masc_mcp.Room.init state.room_config ~agent_name:None);
  Masc_mcp.Chain_native_eio.ensure_bootstrap state.room_config;
  (try Masc_mcp.Tool_command_plane.backfill_chain_overlays state.room_config
   with exn ->
     Printf.eprintf "[chain-backfill] startup backfill failed: %s\n%!"
       (Printexc.to_string exn));
  Mcp_server.set_sse_callback state Sse.broadcast;

  (* Keepers are meant to be long-lived. Start their keepalive fibers on startup
     so liveness/last_seen stays up-to-date even if no tool calls happen. *)
  (try
     let keeper_ctx : _ Tool_keeper.context = { config = state.room_config; sw; clock } in
     let stats = Keeper_runtime.bootstrap_existing_keepers keeper_ctx in
     if stats.enabled then
       Printf.eprintf
         "[keeper-bootstrap] scanned=%d started=%d stale=%d\n%!"
         stats.scanned stats.started stats.stale
   with exn -> Printf.eprintf "[main] keeper bootstrap failed: %s\n%!" (Printexc.to_string exn));

  (* Initialize Task backend - share pool with Board if PostgreSQL available *)
  (match Board_dispatch.get_pg_pool () with
   | Some pool ->
       (match Task_dispatch.init_pg pool with
        | Ok () -> Printf.eprintf "[Task_dispatch] PostgreSQL backend initialized\n%!"
        | Error e -> Printf.eprintf "[Task_dispatch] PG init failed: %s, using JSONL\n%!" (Types.show_masc_error e))
   | None -> Task_dispatch.init_jsonl ());
  Progress.set_sse_callback Sse.broadcast;
  let cancel_orchestrator = Masc_mcp.Orchestrator.start ~sw ~proc_mgr ~clock ~domain_mgr state.room_config in
  (* Store cancel function for graceful shutdown *)
  Masc_mcp.Shutdown_hooks.register_cancel_orchestrator cancel_orchestrator;
  (* Lodge world heartbeat - wakes agents every 60s *)
  Masc_mcp.Lodge_heartbeat.start ~sw ~clock state.room_config;
  (* Gardener — self-organizing agent ecosystem (task-aware, LLM-primary) *)
  Masc_mcp.Gardener.start ~sw ~clock ~room_config:state.room_config;
  if Masc_mcp.Env_config.Sentinel.enabled then begin
    (* Sentinel is the SSOT for housekeeping. It embeds zombie/gc loops itself. *)
    Masc_mcp.Sentinel.start ~sw ~clock ~net state.room_config;
    (* Lodge patrol remains a Guardian concern and can still be enabled explicitly. *)
    if Masc_mcp.Env_config.Guardian.enabled then
      Masc_mcp.Guardian.start_lodge_loop ~sw ~clock ~net
  end else
    (* Fallback runtime when sentinel is disabled. *)
    Masc_mcp.Guardian.start ~sw ~clock ~net state.room_config;
  Masc_mcp.Dashboard_governance_judge.start ~sw ~clock
    ~base_path:state.room_config.base_path
    ~build_facts:(fun () ->
      Masc_mcp.Dashboard_governance.factual_snapshot_json
        ~base_path:state.room_config.base_path)
    ();
  let operator_judge_ctx : _ Operator_control.context =
    {
      config = state.room_config;
      agent_name = "operator-judge";
      sw;
      clock;
      proc_mgr = Some proc_mgr;
      mcp_session_id = None;
    }
  in
  Masc_mcp.Dashboard_operator_judge.start ~sw ~clock ~config:state.room_config
    ~build_facts:(fun () ->
      Operator_control.snapshot_json ~actor:"operator-judge" ~view:"summary"
        ~include_messages:false ~include_keepers:false operator_judge_ctx)
    ();
  (* Start MCP session cleanup loop *)
  Masc_mcp.Session.start_mcp_session_cleanup_loop ~sw ~clock ();

  (* Board Listener — bridges pg_notify to SSE for real-time updates (Phase C) *)
  (match Board_dispatch.get_pg_pool () with
   | Some pool ->
       let listener = Board_listener.create pool in
       Eio.Fiber.fork ~sw (fun () -> Board_listener.start listener);
       Printf.eprintf "[Board_listener] Fiber started for real-time Board events\n%!"
   | None ->
       Printf.eprintf "[Board_listener] Skipped (not using PostgreSQL backend)\n%!");

  (* Periodic SSE stale-client reaper — every 60s, evict connections older than 30min *)
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock 60.0;
      let stale_sids = Masc_mcp.Sse.cleanup_stale () in
      List.iter stop_sse_session stale_sids;
      if stale_sids <> [] then
        Printf.eprintf "[SSE] Reaped %d stale connections (active: %d)\n%!"
          (List.length stale_sids) (Masc_mcp.Sse.client_count ());
      loop ()
    in
    loop ());

  let config = { Http.default_config with port; host } in
  Unix.putenv "MASC_HTTP_BIND_HOST" config.host;
  Unix.putenv "MASC_HTTP_PORT" (string_of_int config.port);
  (match Sys.getenv_opt "MASC_HTTP_BASE_URL" with
   | Some existing when String.trim existing <> "" -> ()
   | _ ->
       let advertised_host =
         if is_unspecified_host config.host then "127.0.0.1" else config.host
       in
       Unix.putenv "MASC_HTTP_BASE_URL"
         (Printf.sprintf "http://%s:%d" advertised_host config.port));
  let routes = make_routes ~port:config.port ~host:config.host ~sw ~clock in
  let request_handler = make_extended_handler routes in
  let h2_request_handler =
    Server_h2_gateway.make_request_handler ~sw ~clock ~server_start_time
  in
  let h2_error_handler = Server_h2_gateway.make_error_handler () in
  let _ = request_handler in
  let _ = h2_request_handler in
  let _ = h2_error_handler in

  let ip =
    match Ipaddr.of_string config.host with
    | Ok addr -> Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets addr)
    | Error _ -> Eio.Net.Ipaddr.V4.loopback
  in
  let addr = `Tcp (ip, config.port) in
  let socket = Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:config.max_connections addr in

  let resolved_base = state.room_config.base_path in
  let masc_dir = Filename.concat resolved_base ".masc" in

  (* Initialize A2A subscription persistence *)
  Masc_mcp.A2a_tools.init ~masc_dir;

  Printf.printf "🚀 MASC MCP Server listening on http://%s:%d\n%!" config.host config.port;
  Printf.printf "   Base path: %s\n%!" resolved_base;
  if resolved_base <> base_path then
    Printf.printf "   Base path (input): %s\n%!" base_path;
  Printf.printf "   MASC dir: %s\n%!" masc_dir;
  Printf.printf "   GET  /mcp → SSE stream (notifications)\n%!";
  Printf.printf
    "   POST /mcp → JSON-RPC (Accept: application/json, text/event-stream)\n\
     %!";
  Printf.printf "   DELETE /mcp → Session termination\n%!";
  Printf.printf
    "   GET  /mcp/operator → Remote operator MCP stream (bearer token required)\n\
     %!";
  Printf.printf
    "   POST /mcp/operator → Remote operator JSON-RPC (4 curated tools only)\n\
     %!";
  Printf.printf
    "   DELETE /mcp/operator → Remote operator session termination\n%!";
  Printf.printf "   POST /graphql → GraphQL (read-only)\n%!";
  Printf.printf
    "   GET  /sse → legacy SSE stream (deprecated; use /mcp)\n%!";
  Printf.printf
    "   POST /messages → legacy client->server messages (deprecated)\n%!";
  Printf.printf "   GET  /health → Health check\n%!";

  (* Defer Lodge init slightly to avoid startup race when GRAPHQL_URL points
     to local /graphql on this same process. *)
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Time.sleep clock 1.0;
    Masc_mcp.Tool_lodge.init ());

  let is_cancelled exn =
    match exn with
    | Eio.Cancel.Cancelled _ -> true
    | _ -> false
  in

  (* HTTP/1.1 accept loop - Cloudflare Tunnel HTTP origin *)
  let rec accept_loop backoff_s =
    try
      let flow, client_addr = Eio.Net.accept ~sw socket in
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Switch.run (fun conn_sw ->
          Eio.Switch.on_release conn_sw (fun () ->
            try Eio.Flow.close flow with _ -> ()
          );
          try
            (* HTTP/1.1 with httpun-eio - Cloudflare provides h2 to browser *)
            let conn_handler = Httpun_eio.Server.create_connection_handler
              ~sw:conn_sw
              ~request_handler:(fun client_addr -> request_handler client_addr)
              ~error_handler:(fun _client_addr ?request:_ error respond ->
                let msg = match error with
                  | `Exn exn -> Printexc.to_string exn
                  | `Bad_request -> "Bad request"
                  | `Bad_gateway -> "Bad gateway"
                  | `Internal_server_error -> "Internal server error"
                in
                let body = respond (Httpun.Headers.of_list [("content-type", "text/plain")]) in
                Httpun.Body.Writer.write_string body msg;
                Httpun.Body.Writer.close body)
            in
            conn_handler client_addr flow
          with exn ->
            Printf.eprintf "[HTTP] Connection error: %s\n%!" (Printexc.to_string exn)
        )
      );
      accept_loop 0.05
    with exn ->
      if is_cancelled exn then ()
      else begin
        Printf.eprintf "Accept error: %s\n%!" (Printexc.to_string exn);
        (try Eio.Time.sleep clock backoff_s with _ -> ());
        accept_loop (Float.min 2.0 (backoff_s *. 1.5))
      end
  in
  accept_loop 0.05

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

  (* Enable Eio-aware locking in Prometheus metrics *)
  Masc_mcp.Prometheus.enable_eio ();
  Masc_mcp.Llm_response_cache.enable_eio ();

  (* Set global clock for Time_compat (Eio-native timestamps) *)
  Masc_mcp.Time_compat.set_clock (Eio.Stdenv.clock env);

  (* Initialize thread-safe token store for cancellation support *)
  Masc_mcp.Cancellation.TokenStore.init ();

  (* Graceful shutdown setup *)
  let switch_ref = ref None in
  let shutdown_initiated = ref false in
  let initiate_shutdown signal_name =
    if not !shutdown_initiated then begin
      shutdown_initiated := true;
      Printf.eprintf "\n🚀 MASC MCP: Received %s, shutting down gracefully...\n%!" signal_name;

      (* Broadcast shutdown notification to all SSE clients *)
      let shutdown_data = Printf.sprintf
        {|{"jsonrpc":"2.0","method":"notifications/shutdown","params":{"reason":"%s","message":"Server is shutting down, please reconnect"}}|}
        signal_name
      in
      Sse.broadcast (Yojson.Safe.from_string shutdown_data);
      Printf.eprintf "🚀 MASC MCP: Sent shutdown notification to %d SSE clients\n%!" (Sse.client_count ());

      (* Give clients 200ms to receive the notification *)
      Unix.sleepf 0.2;

      (* Run all shutdown hooks (cancel orchestrator, close SSE, etc.) *)
      Masc_mcp.Shutdown_hooks.run_all ();

      (* Flush dirty board data to prevent data loss *)
      (try Board_dispatch.flush ()
       with _ -> Printf.eprintf "[Shutdown] Board flush skipped (not initialized)\n%!");

      (* Also close local SSE connections tracked in main_eio *)
      close_all_sse_connections ();

      (* Give connections 200ms to complete close handshake *)
      Unix.sleepf 0.2;

      match !switch_ref with
      | Some sw -> Eio.Switch.fail sw Shutdown
      | None -> ()
    end
  in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle (fun _ -> initiate_shutdown "SIGTERM"));
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ -> initiate_shutdown "SIGINT"));

  let max_bind_retries = 5 in
  let rec try_start attempt =
    (try
      Eio.Switch.run @@ fun sw ->
      switch_ref := Some sw;
      run_server ~sw ~env ~host ~port ~base_path
    with
    | Shutdown ->
        Printf.eprintf "🚀 MASC MCP: Shutdown complete.\n%!"
    | Eio.Cancel.Cancelled _ ->
        Printf.eprintf "🚀 MASC MCP: Shutdown complete.\n%!"
    | Unix.Unix_error (Unix.EADDRINUSE, _, _) when attempt < max_bind_retries ->
        let delay = Float.min 30.0 (2.0 ** Float.of_int attempt) in
        Printf.eprintf "⚠️  Port %d in use, retrying in %.0fs (attempt %d/%d)...\n%!"
          port delay (attempt + 1) max_bind_retries;
        Time_compat.sleep delay;
        try_start (attempt + 1)
    | Unix.Unix_error (Unix.EADDRINUSE, _, _) ->
        Printf.eprintf "❌ [MASC FATAL] Port %d is still in use after %d retries.\n%!"
          port max_bind_retries;
        Printf.eprintf "   Try: lsof -i :%d | grep LISTEN\n%!" port;
        exit 1
    | Unix.Unix_error (Unix.EACCES, _, _) ->
        Printf.eprintf "❌ [MASC FATAL] Permission denied binding to port %d.\n%!" port;
        exit 1)
  in
  try_start 0

let cmd =
  let doc = "MASC MCP Server" in
  let info = Cmd.info "masc-mcp" ~version:Masc_mcp.Version.version ~doc in
  Cmd.v info Term.(const run_cmd $ host $ port $ base_path)

let () = exit (Cmd.eval cmd)
