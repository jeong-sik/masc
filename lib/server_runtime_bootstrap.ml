[@@@warning "-32-33-69"]

open Types
open Server_auth
open Server_routes_http

module Http = Http_server_eio
module Mcp_server = Mcp_server
module Mcp_eio = Mcp_server_eio

let init_runtime_context env =
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  let net = Eio.Stdenv.net env in
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let fs = Eio.Stdenv.fs env in
  (clock, mono_clock, net, domain_mgr, proc_mgr, fs)

let create_server_state ~sw ~base_path ~clock ~mono_clock ~net ~proc_mgr ~fs
    : Mcp_server.server_state =
  Fs_compat.set_fs fs;
  Mcp_eio.set_net net;
  Mcp_eio.set_clock clock;
  Eio_context.set_switch sw;
  Eio_context.set_net net;
  Eio_context.set_clock clock;
  Council.Thread_persist.set_eio_context ~clock
    ~https_connector:(Eio_context.get_https_connector ()) net;
  Process_eio.init ~cwd_default:Eio.Path.(fs / base_path) ~proc_mgr ~clock;
  let caqti_env : Caqti_eio.stdenv =
    object
      method net = (net :> [`Generic] Eio.Net.ty Eio.Resource.t)
      method clock = clock
      method mono_clock = mono_clock
    end
  in
  Unix.putenv "MASC_BASE_PATH_INPUT" base_path;
  let state =
    Mcp_eio.create_state_eio ~sw ~env:caqti_env ~proc_mgr ~fs ~clock ~net
      ~base_path
  in
  server_state := Some state;
  state

let bootstrap_server_state (state : Mcp_server.server_state) =
  ignore (Room.init state.room_config ~agent_name:None);
  Chain_native_eio.ensure_bootstrap state.room_config;
  (try Tool_command_plane.backfill_chain_overlays state.room_config
   with exn ->
     Printf.eprintf "[chain-backfill] startup backfill failed: %s\n%!"
       (Printexc.to_string exn));
  Mcp_server.set_sse_callback state Sse.broadcast

let bootstrap_keepers ~sw ~clock (state : Mcp_server.server_state) =
  try
    let keeper_ctx : _ Tool_keeper.context =
      {
        config = state.room_config;
        agent_name = "keeper-bootstrap";
        sw;
        clock;
        proc_mgr = state.Mcp_server.proc_mgr;
      }
    in
    let stats = Keeper_runtime.bootstrap_existing_keepers keeper_ctx in
    if stats.enabled then
      Printf.eprintf
        "[keeper-bootstrap] scanned=%d started=%d stale=%d recovering=%d\n%!"
        stats.scanned stats.started stats.stale stats.recovering
  with exn ->
    Printf.eprintf "[main] keeper bootstrap failed: %s\n%!"
      (Printexc.to_string exn)

let init_task_backend () =
  match Board_dispatch.get_pg_pool () with
  | Some pool -> (
      match Task_dispatch.init_pg pool with
      | Ok () ->
          Printf.eprintf "[Task_dispatch] PostgreSQL backend initialized\n%!"
      | Error e ->
          Printf.eprintf "[Task_dispatch] PG init failed: %s, using JSONL\n%!"
            (Types.show_masc_error e))
  | None -> Task_dispatch.init_jsonl ()

let start_resident_loops ~sw ~clock ~net ~domain_mgr ~proc_mgr
    (state : Mcp_server.server_state) =
  Progress.set_sse_callback Sse.broadcast;
  (* OAS Event_bus: shared instance for cross-subsystem communication *)
  let event_bus = Agent_sdk.Event_bus.create () in
  let cancel_orchestrator =
    Orchestrator.start ~sw ~proc_mgr ~clock ~domain_mgr state.room_config
  in
  Shutdown_hooks.register_cancel_orchestrator cancel_orchestrator;
  Social_runtime.start ~sw ~clock ~config:state.room_config;
  Gardener.start ~bus:event_bus ~sw ~clock ~room_config:state.room_config ();
  if Env_config.Sentinel.enabled then begin
    Sentinel.start ~bus:event_bus ~sw ~clock ~net state.room_config;
    if Env_config.Guardian.enabled then Guardian.start_lodge_loop ~sw ~clock ~net
  end else Guardian.start ~bus:event_bus ~sw ~clock ~net state.room_config;
  Dashboard_governance_judge.start ~sw ~clock
    ~base_path:state.room_config.base_path
    ~build_facts:(fun () ->
      Dashboard_governance.factual_snapshot_json
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
  Dashboard_operator_judge.start ~sw ~clock ~config:state.room_config
    ~build_facts:(fun () ->
      Operator_control.snapshot_json ~actor:"operator-judge" ~view:"summary"
        ~include_messages:false ~include_keepers:false operator_judge_ctx)
    ();
  Session.start_mcp_session_cleanup_loop ~sw ~clock ();
  (* Phase 5: unified startup subsystem summary *)
  let on_off b = if b then "on" else "off" in
  Log.info ~ctx:"startup" "subsystems: sentinel=%s guardian=%s gardener=%s"
    (on_off Env_config.Sentinel.enabled)
    (on_off Env_config.Guardian.enabled)
    (on_off Env_config.Gardener.enabled)

let start_background_maintenance ~sw ~clock (state : Mcp_server.server_state) =
  (match Board_dispatch.get_pg_pool () with
  | Some pool ->
      let listener = Board_listener.create pool in
      Eio.Fiber.fork ~sw (fun () -> Board_listener.start listener);
      Printf.eprintf
        "[Board_listener] Fiber started for real-time Board events\n%!"
  | None ->
      Printf.eprintf
        "[Board_listener] Skipped (not using PostgreSQL backend)\n%!");
  Eio.Fiber.fork ~sw (fun () ->
      let rec loop () =
        Eio.Time.sleep clock 60.0;
        let stale_sids = Sse.cleanup_stale () in
        List.iter stop_sse_session stale_sids;
        if stale_sids <> [] then
          Printf.eprintf "[SSE] Reaped %d stale connections (active: %d)\n%!"
            (List.length stale_sids) (Sse.client_count ());
        loop ()
      in
      loop ());
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Time.sleep clock 1.0;
      Tool_lodge.init ());
  let resolved_base = state.room_config.base_path in
  let masc_dir = Filename.concat resolved_base ".masc" in
  A2a_tools.init ~masc_dir;
  (resolved_base, masc_dir)

let make_http_config ~host ~port : Http.config =
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
  config

let listen_socket ~sw ~net (config : Http.config) =
  let ip =
    match Ipaddr.of_string config.host with
    | Ok addr -> Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets addr)
    | Error _ -> Eio.Net.Ipaddr.V4.loopback
  in
  let addr = `Tcp (ip, config.port) in
  Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:config.max_connections addr

let print_startup_banner ~(config : Http.config) ~resolved_base ~base_path
    ~masc_dir =
  Printf.printf "MASC MCP Server listening on http://%s:%d\n%!" config.host
    config.port;
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
  Printf.printf "   GET  /sse → legacy SSE stream (deprecated; use /mcp)\n%!";
  Printf.printf "   GET  /api/v1/events → Social motion replay API\n%!";
  Printf.printf "   GET  /api/v1/events/stream → Social motion SSE stream\n%!";
  Printf.printf "   GET  /api/v1/social-graph → Social graph snapshot\n%!";
  Printf.printf
    "   POST /messages → legacy client->server messages (deprecated)\n%!";
  Printf.printf "   GET  /health → Health check\n%!"

let serve ~sw ~clock ~socket ~request_handler =
  let is_cancelled exn =
    match exn with
    | Eio.Cancel.Cancelled _ -> true
    | _ -> false
  in
  let rec accept_loop backoff_s =
    try
      let flow, client_addr = Eio.Net.accept ~sw socket in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Switch.run (fun conn_sw ->
              Eio.Switch.on_release conn_sw (fun () ->
                  try Eio.Flow.close flow with _ -> ());
              try
                let conn_handler =
                  Httpun_eio.Server.create_connection_handler ~sw:conn_sw
                    ~request_handler:(fun client_addr ->
                      request_handler client_addr)
                    ~error_handler:(fun _client_addr ?request:_ error respond ->
                      let msg =
                        match error with
                        | `Exn exn -> Printexc.to_string exn
                        | `Bad_request -> "Bad request"
                        | `Bad_gateway -> "Bad gateway"
                        | `Internal_server_error ->
                            "Internal server error"
                      in
                      let body =
                        respond
                          (Httpun.Headers.of_list
                             [ ("content-type", "text/plain") ])
                      in
                      Httpun.Body.Writer.write_string body msg;
                      Httpun.Body.Writer.close body)
                in
                conn_handler client_addr flow
              with exn ->
                Printf.eprintf "[HTTP] Connection error: %s\n%!"
                  (Printexc.to_string exn)))
      ;
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

let run ~sw ~env ~host ~port ~base_path ~make_routes ~make_request_handler
    ~make_h2_request_handler ~make_h2_error_handler =
  let clock, mono_clock, net, domain_mgr, proc_mgr, fs =
    init_runtime_context env
  in

  (* 1. HTTP socket first — Railway healthcheck can reach /health immediately *)
  let config = make_http_config ~host ~port in
  let routes = make_routes ~port:config.port ~host:config.host ~sw ~clock in
  let request_handler = make_request_handler routes in
  let _h2_request_handler =
    make_h2_request_handler ~sw ~clock ~server_start_time
  in
  let _h2_error_handler = make_h2_error_handler () in
  let socket = listen_socket ~sw ~net config in

  (* 2. All init in background fiber — protected so failures don't kill HTTP *)
  Eio.Fiber.fork ~sw (fun () ->
    try
      let state =
        create_server_state ~sw ~base_path ~clock ~mono_clock ~net ~proc_mgr ~fs
      in
      bootstrap_server_state state;
      bootstrap_keepers ~sw ~clock state;
      init_task_backend ();
      let resolved_base, masc_dir =
        start_background_maintenance ~sw ~clock state
      in
      print_startup_banner ~config ~resolved_base ~base_path ~masc_dir;
      start_resident_loops ~sw ~clock ~net ~domain_mgr ~proc_mgr state
    with exn ->
      Printf.eprintf "[startup] Background init failed (HTTP still serving): %s\n%!"
        (Printexc.to_string exn));

  (* 3. Start serving — /health responds before init completes *)
  serve ~sw ~clock ~socket ~request_handler
