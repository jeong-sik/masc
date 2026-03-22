
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
  Eio_context.set_mono_clock mono_clock;
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
  let (_init_msg : string) = Room.init state.room_config ~agent_name:None in
  Chain_native_eio.ensure_bootstrap state.room_config;
  (try Tool_command_plane.backfill_chain_overlays state.room_config
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Misc.error "startup backfill failed: %s"
       (Printexc.to_string exn));
  (* Warm up Tool_registry from persistent telemetry.jsonl *)
  (try
     let summary =
       Telemetry_eio.summarize_tool_usage state.room_config
     in
     if summary.telemetry_available then
       let n = Tool_registry.warm_up summary in
       Log.Misc.info "tool registry: warmed up %d tools (%d calls) from telemetry"
         n summary.total_calls
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Misc.error "tool registry warm-up failed: %s"
       (Printexc.to_string exn));
  (* Prune old date-split JSONL files on startup (default: 30 days).
     Iterates known store directories and deletes day-files exceeding retention. *)
  (try
     let days =
       Safe_ops.get_env_int_logged "MASC_JSONL_RETENTION_DAYS" ~default:30
     in
     let masc = Filename.concat state.room_config.base_path ".masc" in
     let prune_dir dir =
       if Sys.file_exists dir then
         Dated_jsonl.prune (Dated_jsonl.create ~base_dir:dir ()) ~days
       else 0
     in
     let total =
       prune_dir (Filename.concat masc "audit")
       + prune_dir (Filename.concat masc "telemetry")
       + prune_dir (Filename.concat (Filename.concat masc "governance") "judgments")
       + (let keepers = Filename.concat masc "perpetual-keepers" in
          if not (Sys.file_exists keepers) then 0
          else
            Array.fold_left (fun acc name ->
              acc + prune_dir (Filename.concat (Filename.concat keepers name) "metrics")
            ) 0 (Sys.readdir keepers))
     in
     if total > 0 then
       Log.Misc.info "startup prune: deleted %d old JSONL day-files (retention=%dd)"
         total days
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Misc.error "startup prune failed: %s" (Printexc.to_string exn));
  (* Prune old keeper checkpoint files: keep only latest 3 per trace session.
     Prevents unbounded growth from AfterTurn hook saving every turn. *)
  (try
     let perpetual_dir =
       Filename.concat
         (Filename.concat state.room_config.base_path ".masc") "perpetual"
     in
     if Sys.file_exists perpetual_dir then begin
       let total = ref 0 in
       Array.iter (fun trace_name ->
         let trace_dir = Filename.concat perpetual_dir trace_name in
         if Sys.is_directory trace_dir then begin
           let files = Sys.readdir trace_dir |> Array.to_list in
           let ckpt_files =
             files
             |> List.filter (fun f ->
               let len = String.length f in
               len > 5 && String.sub f 0 5 = "ckpt-"
               && String.sub f (len - 5) 5 = ".json")
             |> List.sort (fun a b -> compare b a)
           in
           if List.length ckpt_files > 3 then
             List.iteri (fun i f ->
               if i >= 3 then begin
                 (try Sys.remove (Filename.concat trace_dir f)
                  with Sys_error _ -> ());
                 incr total
               end
             ) ckpt_files
         end
       ) (Sys.readdir perpetual_dir);
       if !total > 0 then
         Log.Misc.info "startup prune: deleted %d old keeper checkpoint files" !total
     end
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Misc.error "startup checkpoint prune failed: %s" (Printexc.to_string exn));
  (* Startup GC: archive stale rooms, tasks, sessions, etc.
     Prevents .masc/ from growing unbounded and slowing snapshots.
     Runs at server start so no manual masc_gc invocation is needed. *)
  (try
     let gc_days = Safe_ops.get_env_int_logged "MASC_GC_RETENTION_DAYS" ~default:7 in
     let (_gc_result : string) = Room.gc state.room_config ~days:gc_days () in
     Log.Misc.info "startup gc completed (retention=%dd)" gc_days
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Misc.error "startup gc failed: %s" (Printexc.to_string exn));
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
    Keeper_runtime.maybe_start_supervisor_sweep keeper_ctx stats;
    if stats.enabled then
      Log.Keeper.info "scanned=%d started=%d stale=%d recovering=%d"
        stats.scanned stats.started stats.stale stats.recovering
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Server.error "keeper bootstrap failed: %s"
      (Printexc.to_string exn)

let init_task_backend () =
  match Board_dispatch.get_pg_pool () with
  | Some pool -> (
      match Task_dispatch.init_pg pool with
      | Ok () ->
          Log.Task.info "PostgreSQL backend initialized"
      | Error e ->
          Log.Task.error "PG init failed: %s, using JSONL"
            (Types.show_masc_error e))
  | None -> Task_dispatch.init_jsonl ()

let inject_shared_pg_pool () =
  match Board_dispatch.get_pg_pool () with
  | Some pool ->
      Council.Archive.set_shared_pool pool;
      Log.Server.info "PG shared pool injected into council archive"
  | None ->
      Log.Server.info "No PG pool available; council archive will create own pool"

let init_memory_pg_schema () =
  match Board_dispatch.get_pg_pool () with
  | Some pool -> (
      match Memory_pg.ensure_schema pool with
      | Ok () -> ()
      | Error msg ->
          Log.MemoryPg.error "Schema init failed: %s (long_term_backend will use no-op)" msg)
  | None ->
      Log.MemoryPg.info "No PG pool available; long_term_backend will use JSONL fallback"

let start_resident_loops ~sw ~clock ~net:_net ~domain_mgr ~proc_mgr
    (state : Mcp_server.server_state) =
  Progress.set_sse_callback Sse.broadcast;
  Sse.set_clock clock;
  (* Shared Agent_sdk Event_bus used as the runtime transport between subsystems. *)
  let event_bus = Agent_sdk.Event_bus.create () in
  (* Eio fiber isolation: each subsystem runs in its own fiber.
     If one crashes, others keep running — Eio's structured concurrency.
     Subsystem_health tracks liveness at module level (no init timing dependency). *)
  let fork_subsystem name f =
    Subsystem_health.register name;
    Eio.Fiber.fork ~sw (fun () ->
      try f ()
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Subsystem_health.mark_dead name;
        Log.Server.error "subsystem %s crashed: %s" name
          (Printexc.to_string exn))
  in
  (* Event_bus → SSE bridge: relay masc:* events to dashboard *)
  Oas_sse_bridge.start ~sw ~clock ~bus:event_bus;
  (* Inject Event_bus into keeper resident runtime for telemetry publishing *)
  Keeper_keepalive.set_bus event_bus;
  (* Orchestrator needs synchronous registration for shutdown hook *)
  (try
    let cancel_orchestrator =
      Orchestrator.start ~sw ~proc_mgr ~clock ~domain_mgr state.room_config
    in
    Shutdown_hooks.register_cancel_orchestrator cancel_orchestrator
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Server.error "subsystem orchestrator failed to start: %s"
      (Printexc.to_string exn));
  fork_subsystem "governance_judge" (fun () ->
    Dashboard_governance_judge.start ~sw ~clock
      ~base_path:state.room_config.base_path
      ~build_facts:(fun () ->
        Dashboard_governance.factual_snapshot_json
          ~base_path:state.room_config.base_path)
      ());
  fork_subsystem "operator_judge" (fun () ->
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
      ());
  fork_subsystem "session_cleanup" (fun () ->
    Session.start_mcp_session_cleanup_loop ~sw ~clock ());
  (* Phase 5: unified startup subsystem summary *)
  Log.info ~ctx:"startup" "subsystems: resident loops started"

let start_background_maintenance ~sw ~clock (state : Mcp_server.server_state) =
  (match Board_dispatch.get_pg_pool () with
  | Some pool ->
      let listener = Board_listener.create pool in
      Eio.Fiber.fork ~sw (fun () -> Board_listener.start listener);
      Log.BoardListener.info "Fiber started for real-time Board events"
  | None ->
      Log.BoardListener.info "Skipped (not using PostgreSQL backend)");
  Eio.Fiber.fork ~sw (fun () ->
      let rec loop () =
        Eio.Time.sleep clock 60.0;
        let stale_sids = Sse.cleanup_stale () in
        List.iter stop_sse_session stale_sids;
        if stale_sids <> [] then
          Log.Server.info "Reaped %d stale connections (active: %d)"
            (List.length stale_sids) (Sse.client_count ());
        let evicted_events = Sse.cleanup_expired_events () in
        if evicted_events > 0 then
          Log.Server.info "Evicted %d expired SSE buffer events" evicted_events;
        (* Cache eviction: remove expired entries *)
        let evicted = Cache_eio.evict_expired state.room_config in
        if evicted > 0 then
          Log.Server.info "Cache: evicted %d expired entries" evicted;
        let sse_guards_reaped = Server_mcp_transport_http_sse.reap_stale_guards () in
        let http_guards_reaped = Server_mcp_transport_http.reap_stale_guards () in
        let is_active sid =
          Server_mcp_transport_http_sse.is_active_sse_session sid
          || Server_mcp_transport_http.is_active_sse_session sid
        in
        let sessions_reaped =
          Server_mcp_transport_http_session.reap_stale_sessions
            ~is_active_session:is_active
        in
        if sse_guards_reaped + http_guards_reaped + sessions_reaped > 0 then
          Log.Server.info "reaped %d SSE guards + %d HTTP guards + %d stale sessions"
            sse_guards_reaped http_guards_reaped sessions_reaped;
        loop ()
      in
      loop ());
  (* Lodge init removed -- Lodge heartbeat deprecated (#1596) *)
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
  Printf.printf "   GET  /api/v1/activity/events → Activity replay API\n%!";
  Printf.printf "   GET  /api/v1/activity/graph → Activity graph snapshot\n%!";
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
                  try Eio.Flow.close flow
                  with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn -> Log.Misc.warn "flow close: %s" (Printexc.to_string exn));
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
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Misc.error "Connection error: %s"
                  (Printexc.to_string exn)))
      ;
      accept_loop 0.05
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      if is_cancelled exn then ()
      else begin
        Log.Misc.error "Accept error: %s" (Printexc.to_string exn);
        (try Eio.Time.sleep clock backoff_s
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn -> Log.Misc.warn "backoff sleep: %s" (Printexc.to_string exn));
        accept_loop (Float.min 2.0 (backoff_s *. 1.5))
      end
  in
  accept_loop 0.05

let serve_h2 ~sw ~clock ~socket ~h2_request_handler ~h2_error_handler =
  let is_cancelled exn =
    match exn with
    | Eio.Cancel.Cancelled _ -> true
    | _ -> false
  in
  Log.Server.info "HTTP/2 h2c mode activated (MASC_USE_H2=1)";
  let rec accept_loop backoff_s =
    try
      let flow, client_addr = Eio.Net.accept ~sw socket in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Switch.run (fun conn_sw ->
              Eio.Switch.on_release conn_sw (fun () ->
                  try Eio.Flow.close flow
                  with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn -> Log.Misc.warn "[h2] flow close: %s" (Printexc.to_string exn));
              try
                H2_eio.Server.create_connection_handler ~sw:conn_sw
                  ~request_handler:h2_request_handler
                  ~error_handler:h2_error_handler
                  client_addr
                  flow
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Misc.error "[h2] Connection error: %s"
                  (Printexc.to_string exn)));
      accept_loop 0.05
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      if is_cancelled exn then ()
      else begin
        Log.Misc.error "[h2] Accept error: %s" (Printexc.to_string exn);
        (try Eio.Time.sleep clock backoff_s
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn -> Log.Misc.warn "[h2] backoff sleep: %s" (Printexc.to_string exn));
        accept_loop (Float.min 2.0 (backoff_s *. 1.5))
      end
  in
  accept_loop 0.05

let run ~sw ~env ~host ~port ~base_path ~make_routes ~make_request_handler
    ~make_h2_request_handler ~make_h2_error_handler =
  let clock, mono_clock, net, domain_mgr, proc_mgr, fs =
    init_runtime_context env
  in

  (* Initialize Eio environment for MODEL HTTP calls (cohttp-eio via OAS Provider) *)
  Masc_eio_env.init ~sw ~net ~clock ();
  Discovery_cache.set_env ~sw ~net;

  (* 1. HTTP socket first — Railway healthcheck can reach /health immediately *)
  let config = make_http_config ~host ~port in
  let routes = make_routes ~port:config.port ~host:config.host ~sw ~clock in
  let request_handler = make_request_handler routes in
  let h2_request_handler =
    make_h2_request_handler ~sw ~clock ~server_start_time
  in
  let h2_error_handler = make_h2_error_handler () in
  let use_h2 =
    match Sys.getenv_opt "MASC_USE_H2" with
    | Some "1" | Some "true" -> true
    | _ -> false
  in
  let socket = listen_socket ~sw ~net config in

  (* 2. All init in background fiber — protected so failures don't kill HTTP *)
  Eio.Fiber.fork ~sw (fun () ->
    let init_state () =
      let state =
        create_server_state ~sw ~base_path ~clock ~mono_clock ~net ~proc_mgr ~fs
      in
      bootstrap_server_state state;
      bootstrap_keepers ~sw ~clock state;
      init_task_backend ();
      inject_shared_pg_pool ();
      init_memory_pg_schema ();
      state
    in
    try
      let pg_init_timeout =
        Safe_ops.get_env_float_logged "MASC_PG_INIT_TIMEOUT_SEC" ~default:10.0
      in
      let state =
        let has_pg = match Sys.getenv_opt "MASC_POSTGRES_URL" with
          | Some s when String.trim s <> "" -> true
          | _ -> false
        in
        if has_pg then
          (try
             Eio.Time.with_timeout_exn clock pg_init_timeout init_state
           with Eio.Time.Timeout ->
             Log.Server.error
               "PG init timed out after %.0fs, retrying with JSONL fallback"
               pg_init_timeout;
             Unix.putenv "MASC_POSTGRES_URL" "";
             init_state ())
        else
          init_state ()
      in
      let resolved_base, masc_dir =
        start_background_maintenance ~sw ~clock state
      in
      print_startup_banner ~config ~resolved_base ~base_path ~masc_dir;
      (* Create Executor_pool for CPU-heavy dashboard compute.
         Runs in separate OS domains, bypassing fiber contention. *)
      let exec_pool = Eio.Executor_pool.create ~sw ~domain_count:2 domain_mgr in
      Server_dashboard_http.set_executor_pool exec_pool;
      Log.Server.info "Executor_pool created (2 domains) for dashboard";
      Server_dashboard_http.start_execution_refresh_loop ~state ~sw ~clock ~net ~mono_clock;
      Server_dashboard_http.start_mission_refresh_loop ~state ~sw ~clock;
      Server_dashboard_http.start_operator_refresh_loop ~state ~sw ~clock;
      Server_command_plane_http_support.start_cp_summary_refresh_loop ~state ~sw ~clock;
      start_resident_loops ~sw ~clock ~net ~domain_mgr ~proc_mgr state
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Server.error "Background init failed (HTTP still serving): %s"
        (Printexc.to_string exn));

  (* 3. Start serving — /health responds before init completes *)
  if use_h2 then
    serve_h2 ~sw ~clock ~socket ~h2_request_handler ~h2_error_handler
  else
    serve ~sw ~clock ~socket ~request_handler
