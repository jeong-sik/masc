
open Server_auth
open Server_routes_http

module Mcp_server = Mcp_server
module Mcp_eio = Mcp_server_eio

let pg_env_var_names =
  [| "MASC_POSTGRES_URL"; "DATABASE_URL"; "SUPABASE_DB_URL"; "SB_PG_URL" |]

let force_jsonl_fallback_env () =
  Unix.putenv "MASC_STORAGE_TYPE" "filesystem";
  Array.iter (fun name -> Unix.putenv name "") pg_env_var_names

let requested_backend_mode () =
  match Sys.getenv_opt "MASC_STORAGE_TYPE" with
  | Some raw -> (
      match String.lowercase_ascii (String.trim raw) with
      | "postgres" | "postgresql" | "postgres-native" -> "postgres-native"
      | "filesystem" | "file" | "jsonl" -> "filesystem"
      | "memory" -> "memory"
      | other -> other)
  | None ->
      let has_pg =
        Array.exists
          (fun name ->
            match Sys.getenv_opt name with
            | Some value -> String.trim value <> ""
            | None -> false)
          pg_env_var_names
      in
      if has_pg then "postgres-native" else "filesystem"

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
  state

let restore_persisted_sessions (state : Mcp_server.server_state) =
  Session.restore_from_disk state.session_registry
    ~agents_path:(Room.agents_dir state.room_config)

let reconcile_active_agents_gauge (state : Mcp_server.server_state) =
  Prometheus.reconcile_active_agents_gauge (Room.masc_dir state.room_config)

let bootstrap_server_state_blocking (state : Mcp_server.server_state) =
  let (_init_msg : string) = Room.init state.room_config ~agent_name:None in
  Mcp_server.set_sse_callback state Sse.broadcast

let bootstrap_chain_state (state : Mcp_server.server_state) =
  Chain_native_eio.ensure_bootstrap state.room_config;
  (* Initialize prompt registry with defaults and restore saved overrides *)
  let prompt_markdown_dir =
    Prompt_defaults.bootstrap_runtime
      ~workspace_path:state.room_config.workspace_path
      ~base_path:state.room_config.base_path
  in
  if prompt_markdown_dir
     <> Filename.concat state.room_config.workspace_path "config/prompts"
  then
    Log.Misc.info "prompt markdown dir resolved outside room base: %s"
      prompt_markdown_dir;
  let missing_prompt_files = Prompt_registry.validate_required_prompt_files () in
  if missing_prompt_files <> [] then
    Log.Misc.error "required prompt files missing: %s"
      (missing_prompt_files
      |> List.map (fun (key, path) -> Printf.sprintf "%s -> %s" key path)
      |> String.concat ", ");
  let invalid_prompt_templates = Prompt_registry.validate_prompt_templates () in
  if invalid_prompt_templates <> [] then
    Log.Misc.error "prompt templates use unknown variables: %s"
      (invalid_prompt_templates
      |> List.map (fun (key, variable) -> Printf.sprintf "%s -> %s" key variable)
      |> String.concat ", ");
  (try Tool_command_plane.backfill_chain_overlays state.room_config
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Misc.error "startup backfill failed: %s"
       (Printexc.to_string exn))

let warm_tool_registry_from_telemetry (state : Mcp_server.server_state) =
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
       (Printexc.to_string exn))

let restore_tool_metrics_from_disk (state : Mcp_server.server_state) =
  (try
     let n = Tool_metrics_persist.restore
       ~base_path:state.room_config.base_path in
     if n > 0 then
       Log.Misc.info "tool metrics: restored %d records from disk" n
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Misc.error "tool metrics restore failed: %s"
       (Printexc.to_string exn))

let startup_prune_jsonl (state : Mcp_server.server_state) =
  (try
     let days =
       Safe_ops.get_env_int_logged "MASC_JSONL_RETENTION_DAYS" ~default:30
     in
     let masc = Room.masc_dir state.room_config in
     let prune_dir dir =
       if Sys.file_exists dir then
         Dated_jsonl.prune (Dated_jsonl.create ~base_dir:dir ()) ~days
       else 0
     in
     let tool_metrics_dir =
       Filename.concat state.room_config.base_path "data/tool-metrics"
     in
     let total =
       prune_dir (Filename.concat masc "audit")
       + prune_dir (Filename.concat masc "telemetry")
       + prune_dir (Filename.concat (Filename.concat masc "governance") "judgments")
       + prune_dir tool_metrics_dir
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
   | exn -> Log.Misc.error "startup prune failed: %s" (Printexc.to_string exn))

let startup_prune_keeper_checkpoints (state : Mcp_server.server_state) =
  (try
     let perpetual_dir =
       Filename.concat (Room.masc_root_dir state.room_config) "perpetual"
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
     Log.Misc.error "startup checkpoint prune failed: %s"
       (Printexc.to_string exn))

let bootstrap_keepers ~sw ~clock (state : Mcp_server.server_state) =
  let timeout_s =
    Safe_ops.get_env_float_logged "MASC_KEEPER_BOOTSTRAP_TIMEOUT_S" ~default:15.0
  in
  let keeper_ctx : _ Tool_keeper.context =
    {
      config = state.room_config;
      agent_name = "keeper-bootstrap";
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
    }
  in
  let fallback_stats : Keeper_runtime.keeper_bootstrap_stats =
    {
      enabled = Env_config.KeeperBootstrap.enabled;
      scanned = 0;
      started = 0;
      stale = 0;
      recovering = 0;
    }
  in
  try
    match
      Eio.Time.with_timeout clock timeout_s (fun () ->
        let stats = Keeper_runtime.bootstrap_existing_keepers keeper_ctx in
        Keeper_runtime.maybe_start_supervisor_sweep keeper_ctx stats;
        if stats.enabled then
          Log.Keeper.info "scanned=%d started=%d stale=%d recovering=%d"
            stats.scanned stats.started stats.stale stats.recovering;
        Ok ())
    with
    | Ok () -> ()
    | Error `Timeout -> begin
        Keeper_runtime.maybe_start_supervisor_sweep keeper_ctx fallback_stats;
        Log.Server.warn
          "keeper bootstrap timed out after %.0fs; resident supervisor sweep will retry recovery"
          timeout_s
      end
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> begin
      Keeper_runtime.maybe_start_supervisor_sweep keeper_ctx fallback_stats;
      Log.Server.error "keeper bootstrap failed: %s"
        (Printexc.to_string exn)
    end

let run ~sw ~env ~host ~port ~base_path ~make_routes ~make_request_handler
    ~make_h2_request_handler ~make_h2_error_handler =
  let clock, mono_clock, net, domain_mgr, proc_mgr, fs =
    init_runtime_context env
  in

  (* Initialize Eio environment for MODEL HTTP calls (cohttp-eio via OAS Provider) *)
  Masc_eio_env.init ~sw ~net ~clock ();
  Discovery_cache.set_env ~sw ~net;
  let refresh_llama_endpoints () =
    try
      let llama_endpoints =
        Llm_provider.Provider_registry.refresh_llama_endpoints ~sw ~net ()
      in
      Log.Server.info "[MASC] Llama endpoints: %s"
        (String.concat ", " llama_endpoints)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Server.warn "llama endpoint refresh skipped during startup: %s"
        (Printexc.to_string exn)
  in

  (* 1. HTTP socket first — Railway healthcheck can reach /health immediately *)
  let config = Server_bootstrap_http.make_http_config ~host ~port in
  let routes = make_routes ~port:config.port ~host:config.host ~sw ~clock in
  let request_handler = make_request_handler routes in
  let h2_request_handler =
    make_h2_request_handler ~sw ~clock ~server_start_time
  in
  let h2_error_handler = make_h2_error_handler () in
  let http_mode =
    match Sys.getenv_opt "MASC_USE_H2" with
    | Some "1" | Some "true" -> `H2_only
    | Some "0" | Some "false" -> `H1_only
    | Some "auto" -> `Auto
    | None -> `Auto
    | Some other ->
      Log.Server.warn "MASC_USE_H2=%s unrecognised, falling back to auto" other;
      `Auto
  in
  let socket = Server_bootstrap_http.listen_socket ~sw ~net config in
  let initial_backend_mode = requested_backend_mode () in
  server_state := None;
  Server_startup_state.reset ~backend_mode:initial_backend_mode ();

  (* 2. All init in background fiber — protected so failures don't kill HTTP *)
  Eio.Fiber.fork ~sw (fun () ->
    refresh_llama_endpoints ();
    let governance_level =
      Sys.getenv_opt "MASC_GOVERNANCE_LEVEL"
      |> Option.value ~default:"production"
      |> String.lowercase_ascii
    in
    let init_state_blocking () =
      let pg_pool_timeout =
        Safe_ops.get_env_float_logged "MASC_PG_POOL_TIMEOUT_SEC" ~default:30.0
      in
      let t0 = Eio.Time.now clock in
      let state =
        (try
           Eio.Time.with_timeout_exn clock pg_pool_timeout (fun () ->
             create_server_state ~sw ~base_path ~clock ~mono_clock ~net ~proc_mgr
               ~fs)
         with Eio.Time.Timeout ->
           Log.Server.error
             "PG pool creation timed out after %.0fs (inner limit); \
              outer timeout will trigger JSONL fallback"
             pg_pool_timeout;
           raise Eio.Time.Timeout)
      in
      let t1 = Eio.Time.now clock in
      Log.Server.info "State created (PG pool) in %.1fs" (t1 -. t0);
      bootstrap_server_state_blocking state;
      let t2 = Eio.Time.now clock in
      Log.Server.info "Bootstrap completed in %.1fs" (t2 -. t1);
      Server_bootstrap_loops.install_tooling ~governance_level state;
      Server_bootstrap_pg.init_pg_schemas_sequential ();
      Log.Server.info "Tooling + schemas in %.1fs" (Eio.Time.now clock -. t2);
      state
    in
    let run_lazy_task (task_name, task_fn) =
      try
        task_fn ();
        Server_startup_state.finish_lazy_task ~task:task_name
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          let error = Printexc.to_string exn in
          Log.Server.error "lazy startup task %s failed: %s" task_name error;
          Server_startup_state.fail_lazy_task ~task:task_name ~error
    in
    let start_lazy_startup state =
      let tasks =
        [
          ("restore_sessions", fun () -> restore_persisted_sessions state);
          ("reconcile_active_agents", fun () -> reconcile_active_agents_gauge state);
          ( "recover_running_team_sessions",
            fun () ->
              let env = object
                method clock = clock
                method process_mgr = match state.Mcp_server.proc_mgr with Some pm -> pm | None -> failwith "process_mgr not available"
              end in
              Team_session_engine_eio.recover_running_sessions ~sw ~env
                ~config:state.Mcp_server.room_config );
          ("chain_bootstrap", fun () -> bootstrap_chain_state state);
          ("telemetry_warmup", fun () -> warm_tool_registry_from_telemetry state);
          ("tool_metrics_restore", fun () -> restore_tool_metrics_from_disk state);
          ("jsonl_prune", fun () -> startup_prune_jsonl state);
          ( "keeper_checkpoint_prune",
            fun () -> startup_prune_keeper_checkpoints state );
          ("keeper_bootstrap", fun () -> bootstrap_keepers ~sw ~clock state);
        ]
      in
      let task_names = List.map fst tasks in
      Server_startup_state.activate_lazy
        ~backend_mode:(Room.backend_name state.room_config)
        ~tasks:task_names;
      Eio.Fiber.fork ~sw (fun () -> List.iter run_lazy_task tasks)
    in
    try
      let pg_init_timeout =
        Safe_ops.get_env_float_logged "MASC_PG_INIT_TIMEOUT_SEC" ~default:30.0
      in
      Server_startup_state.mark_blocking ~backend_mode:initial_backend_mode;
      let state =
        if String.equal initial_backend_mode "postgres-native" then
          (try
             Eio.Time.with_timeout_exn clock pg_init_timeout init_state_blocking
           with Eio.Time.Timeout ->
             let reason =
               Printf.sprintf
                 "PG init timed out after %.0fs, retrying with JSONL fallback"
                 pg_init_timeout
             in
             Log.Server.error
               "%s" reason;
             Server_startup_state.note_fallback reason;
             force_jsonl_fallback_env ();
             Server_startup_state.mark_blocking ~backend_mode:"filesystem";
             init_state_blocking ())
        else
          init_state_blocking ()
      in
      server_state := Some state;
      Server_startup_state.mark_state_ready
        ~backend_mode:(Room.backend_name state.room_config);
      let resolved_base, masc_dir =
        Server_bootstrap_loops.start_background_maintenance ~sw ~clock state
      in
      Server_bootstrap_http.print_startup_banner ~config ~resolved_base ~base_path ~masc_dir;
      (* Create Executor_pool for CPU-heavy dashboard compute.
         Runs in separate OS domains, bypassing fiber contention. *)
      let exec_pool = Eio.Executor_pool.create ~sw ~domain_count:2 domain_mgr in
      Server_dashboard_http.set_executor_pool exec_pool;
      Log.Server.info "Executor_pool created (2 domains) for dashboard";
      (* Stagger PG-heavy refresh loop warm-cache runs at startup.
         Each Proactive_refresh.start forks a fiber that immediately calls
         compute(), so starting all 7 loops at once creates 7+ concurrent PG
         queries — exceeding pool capacity on Supabase session pooler.
         A short sleep between PG-heavy launches spreads the initial burst. *)
      Server_command_plane_http_support.start_cp_summary_refresh_loop ~state ~sw ~clock;
      Eio.Time.sleep clock 0.5;
      Server_command_plane_http_support.start_cp_snapshot_refresh_loop ~state ~sw ~clock;
      Eio.Time.sleep clock 0.5;
      Server_dashboard_http.start_execution_refresh_loop ~state ~sw ~clock ~net ~mono_clock;
      Eio.Time.sleep clock 0.5;
      (* transport_health is light (no PG), start immediately. *)
      Server_dashboard_http.start_transport_health_refresh_loop ~state ~sw ~clock;
      (* mission and operator loops are PG-heavy — stagger to avoid pool
         exhaustion that causes "Invalid concurrent usage" errors. *)
      Eio.Time.sleep clock 1.0;
      Server_dashboard_http.start_mission_refresh_loop ~state ~sw ~clock;
      Eio.Time.sleep clock 1.0;
      Server_dashboard_http.start_operator_snapshot_refresh_loop ~state ~sw ~clock;
      Eio.Time.sleep clock 1.0;
      Server_dashboard_http.start_operator_digest_refresh_loop ~state ~sw ~clock;
      (* Start auxiliary transports before optional warmups and resident loops.
         Otherwise HTTP can report ready while gRPC/WS startup is still stuck
         behind heavier startup work. *)
      (* gRPC coordination transport (opt-in via MASC_GRPC_ENABLED=1) *)
      let tool_dispatcher tool_name args_json =
        let arguments =
          try Yojson.Safe.from_string args_json
          with Yojson.Json_error _ -> `Assoc []
        in
        let (success, result_str) =
          Mcp_server_eio_execute.execute_tool_eio ~sw ~clock state
            ~name:tool_name ~arguments
        in
        if success then Ok result_str else Error result_str
      in
      Masc_grpc_server.start ~sw ~env ~room_config:state.room_config
        ~tool_dispatcher;
      (* Standalone WebSocket transport (enabled by default, opt-out via MASC_WS_ENABLED=0) *)
      Server_ws_standalone.start ~sw ~env
        ~on_message:(fun ws_session_id body_str ->
          Eio.Fiber.fork ~sw (fun () ->
            try
              let response_json =
                Mcp_eio.handle_request ~clock ~sw
                  ~mcp_session_id:ws_session_id state body_str
              in
              let response_str = Yojson.Safe.to_string response_json in
              if response_str <> "null" then
                ignore (Server_mcp_transport_ws.send_to_session ws_session_id response_str)
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
              Log.Server.warn "WS dispatch error %s: %s" ws_session_id (Printexc.to_string exn)));
      (* WebRTC DataChannel transport (enabled by default, opt-out via MASC_WEBRTC_ENABLED=0) *)
      if Server_webrtc_transport.is_enabled () then (
        Log.Server.info "WebRTC DataChannel transport enabled";
        Server_webrtc_transport.set_message_handler
          (fun peer_id body_str ->
            Eio.Fiber.fork ~sw (fun () ->
              try
                let response_json =
                  Mcp_eio.handle_request ~clock ~sw
                    ~mcp_session_id:peer_id state body_str
                in
                let response_str = Yojson.Safe.to_string response_json in
                if response_str <> "null" then
                  ignore (Server_webrtc_transport.send_to_peer peer_id response_str)
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Server.warn "WebRTC dispatch error %s: %s"
                  peer_id (Printexc.to_string exn)));
        Server_webrtc_transport.set_connection_starter
          (fun peer_id ->
            Server_webrtc_transport.start_webrtc_connection ~sw ~env peer_id));
      (* Pre-warm shell cache so the first /dashboard load is instant.
         shell is the only room-truth component without a proactive refresh loop. *)
      Server_dashboard_http.warm_shell_cache state;
      Server_bootstrap_loops.start_resident_loops ~sw ~clock ~net ~domain_mgr ~proc_mgr state;
      start_lazy_startup state
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Server_startup_state.mark_degraded ~error:(Printexc.to_string exn);
      Log.Server.error "Background init failed (HTTP still serving): %s"
        (Printexc.to_string exn));

  (* 2b. Startup watchdog: if init does not reach state_ready within timeout,
     log and exit so external process managers can restart the server.
     Prevents zombie-listener state where the socket is open but HTTP
     requests hang because init is stuck. *)
  Eio.Fiber.fork ~sw (fun () ->
    try
      let timeout_sec = Server_startup_state.watchdog_timeout_sec () in
      Eio.Time.sleep clock timeout_sec;
      let current = Server_startup_state.(!state) in
      if not current.state_ready then (
        let elapsed = Server_startup_state.elapsed_since_start () in
        Log.Server.error
          "[watchdog] Server init did not complete within %.0fs (elapsed=%.1fs, phase=%s, backend=%s). Exiting."
          timeout_sec elapsed
          (Server_startup_state.phase_to_string current.phase)
          current.backend_mode;
        exit 1)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Server.error "startup watchdog fiber failed: %s"
        (Printexc.to_string exn));

  (* 3. Start serving -- /health responds before init completes *)
  match http_mode with
  | `H2_only ->
    Server_bootstrap_http.serve_h2 ~sw ~clock ~socket ~h2_request_handler ~h2_error_handler
  | `H1_only ->
    Server_bootstrap_http.serve ~sw ~clock ~socket ~request_handler
  | `Auto ->
    Server_bootstrap_http.serve_auto ~sw ~clock ~socket ~request_handler ~h2_request_handler
      ~h2_error_handler
