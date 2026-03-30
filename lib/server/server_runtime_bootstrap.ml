
open Server_auth
open Server_routes_http

module Mcp_server = Mcp_server
module Mcp_eio = Mcp_server_eio

let pg_env_var_names =
  [| "MASC_POSTGRES_URL" |]

let force_jsonl_fallback_env () =
  Unix.putenv "MASC_STORAGE_TYPE" "filesystem";
  Array.iter (fun name -> Unix.putenv name "") pg_env_var_names

let requested_backend_mode () =
  Env_config_core.storage_type ()

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
  let https_connector =
    match Eio_context.get_https_connector_result () with
    | Ok connector -> Some connector
    | Error message ->
        Log.Server.warn
          "HTTPS connector unavailable during bootstrap; HTTPS persistence calls will be disabled: %s"
          message;
        None
  in
  Council.Thread_persist.set_eio_context ?https_connector ~clock net;
  Process_eio.init ~cwd_default:Eio.Path.(fs / base_path) ~proc_mgr ~clock;
  let caqti_env : Caqti_eio.stdenv =
    object
      method net = (net :> [`Generic] Eio.Net.ty Eio.Resource.t)
      method clock = clock
      method mono_clock = mono_clock
    end
  in
  Unix.putenv "MASC_BASE_PATH" base_path;
  let state =
    Mcp_eio.create_state_eio ~sw ~env:caqti_env ~proc_mgr ~fs ~clock
      ~mono_clock ~net
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
  Config_dir_resolver.log_warnings ~context:"ServerBootstrap" ();
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
       + prune_dir (Filename.concat masc "messages")
       + prune_dir (Filename.concat masc "events")
       + prune_dir (Filename.concat masc "activity-events")
       + prune_dir (Filename.concat masc "voice_sessions")
       + (let keepers = Filename.concat masc "keepers" in
          if not (Sys.file_exists keepers) then 0
          else
            Array.fold_left (fun acc name ->
              acc
              + prune_dir (Filename.concat (Filename.concat keepers name) "metrics")
              + prune_dir (Filename.concat (Filename.concat keepers name) "crash-events")
            ) 0 (Sys.readdir keepers))
     in
     if total > 0 then
         Log.Misc.info "startup prune: deleted %d old JSONL day-files (retention=%dd)"
         total days
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn -> Log.Misc.error "startup prune failed: %s" (Printexc.to_string exn))

(** Migrate legacy directory names: perpetual->traces, perpetual-keepers->keepers.
    Moves contents via recursive merge. Conflicting files go to _quarantine/,
    except keeper meta files where a fresher valid legacy record may replace a
    stale or invalid current record. *)
let keeper_meta_updated_ts (meta : Keeper_types.keeper_meta) =
  Resilience.Time.parse_iso8601_opt meta.updated_at
  |> Option.value ~default:0.0

let should_promote_legacy_keeper_meta ~legacy_path ~current_path =
  match
    Keeper_types.read_meta_file_path legacy_path,
    Keeper_types.read_meta_file_path current_path
  with
  | Ok (Some _legacy), Ok (Some _current) -> (
      keeper_meta_updated_ts _legacy > keeper_meta_updated_ts _current)
  | Ok (Some _), Ok None | Ok (Some _), Error _ -> true
  | _ -> false

let migrate_legacy_dirs (state : Mcp_server.server_state) =
  let masc = Room.masc_root_dir state.room_config in
  let quarantine = Filename.concat masc "_quarantine" in
  let rec migrate_recursive ~old_dir ~new_dir ~rel_path
      ~prefer_root_keeper_meta_conflicts =
    if not (Sys.file_exists old_dir) then ()
    else begin
      Keeper_types.mkdir_p new_dir;
      Array.iter (fun name ->
        let old_path = Filename.concat old_dir name in
        let new_path = Filename.concat new_dir name in
        let rel = if rel_path = "" then name else Filename.concat rel_path name in
        if Sys.is_directory old_path then begin
          if Sys.file_exists new_path then
            migrate_recursive ~old_dir:old_path ~new_dir:new_path ~rel_path:rel
              ~prefer_root_keeper_meta_conflicts
          else
            Sys.rename old_path new_path
        end else begin
          if Sys.file_exists new_path then begin
            if prefer_root_keeper_meta_conflicts && rel_path = ""
               && Filename.check_suffix name ".json"
               && should_promote_legacy_keeper_meta
                    ~legacy_path:old_path ~current_path:new_path
            then begin
              let replaced_q_path =
                Filename.concat quarantine (Filename.concat "_replaced" rel)
              in
              Keeper_types.mkdir_p (Filename.dirname replaced_q_path);
              Sys.rename new_path replaced_q_path;
              Sys.rename old_path new_path
            end else begin
              let q_path = Filename.concat quarantine rel in
              Keeper_types.mkdir_p (Filename.dirname q_path);
              Sys.rename old_path q_path
            end
          end else
            Sys.rename old_path new_path
        end
      ) (Sys.readdir old_dir);
      (try
        if Array.length (Sys.readdir old_dir) = 0 then
          Sys.rmdir old_dir
        else
          Log.Misc.warn "migrate: old dir not empty after migration: %s" old_dir
      with Sys_error _ -> ())
    end
  in
  let renames = [
    ("perpetual", "traces");
    ("perpetual-keepers", "keepers");
    ("resident-keepers", "keepers");
  ] in
  (try
    List.iter (fun (old_name, new_name) ->
      let old_dir = Filename.concat masc old_name in
      let new_dir = Filename.concat masc new_name in
      if Sys.file_exists old_dir then begin
        Log.Misc.info "migrate: %s -> %s" old_name new_name;
        migrate_recursive ~old_dir ~new_dir ~rel_path:""
          ~prefer_root_keeper_meta_conflicts:(String.equal new_name "keepers")
      end
    ) renames
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Misc.error "legacy dir migration failed: %s" (Printexc.to_string exn))

let startup_prune_keeper_checkpoints (state : Mcp_server.server_state) =
  (try
     let traces_dir =
       Filename.concat (Room.masc_root_dir state.room_config) "traces"
     in
     if Sys.file_exists traces_dir then begin
       let total = ref 0 in
       Array.iter (fun trace_name ->
         let trace_dir = Filename.concat traces_dir trace_name in
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
       ) (Sys.readdir traces_dir);
       if !total > 0 then
         Log.Misc.info "startup prune: deleted %d old keeper checkpoint files" !total
     end
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Misc.error "startup checkpoint prune failed: %s"
       (Printexc.to_string exn))

(* bootstrap_keepers removed: the keeper_autoboot subsystem in
   start_keeper_loops now handles keeper startup in a dedicated
   fiber with a 5-second delay, avoiding PG pool contention with
   the 7+ dashboard refresh loops that share the same pool. *)

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
    match Env_config.Transport.use_h2 () with
    | "h2_only" -> `H2_only
    | "h1_only" -> `H1_only
    | _ -> `Auto
  in
  let socket = Server_bootstrap_http.listen_socket ~sw ~net config in
  let initial_backend_mode = requested_backend_mode () in
  server_state := None;
  Server_startup_state.reset ~backend_mode:initial_backend_mode ();

  (* 2. All init in background fiber — protected so failures don't kill HTTP *)
  Eio.Fiber.fork ~sw (fun () ->
    refresh_llama_endpoints ();
    let governance_level = Env_config_core.governance_level () in
    let init_state_blocking () =
      let t0 = Eio.Time.now clock in
      let state =
        create_server_state ~sw ~base_path ~clock ~mono_clock ~net ~proc_mgr ~fs
      in
      let t1 = Eio.Time.now clock in
      Log.Server.info "State created (PG pool) in %.1fs" (t1 -. t0);
      bootstrap_server_state_blocking state;
      Governance_registry.ensure_init ();
      Runtime_params.restore ~base_path;
      Log.Server.info "Runtime_params restored from %s" base_path;
      Keeper_crash_persistence.start_drain_fiber ~sw ~clock;
      let t2 = Eio.Time.now clock in
      Log.Server.info "Bootstrap completed in %.1fs" (t2 -. t1);
      Server_bootstrap_loops.install_tooling ~governance_level state;
      Server_bootstrap_pg.init_pg_schemas_sequential ();
      Log.Server.info "Tooling + schemas in %.1fs" (Eio.Time.now clock -. t2);
      state
    in
    let run_lazy_task (task_name, task_fn) =
      Log.Server.info "lazy_task: starting %s" task_name;
      try
        task_fn ();
        Log.Server.info "lazy_task: finished %s" task_name;
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
              match state.Mcp_server.proc_mgr with
              | None ->
                  Log.Server.warn
                    "skipping team session recovery: process_mgr not available"
              | Some process_mgr ->
                  let env = object
                    method clock = clock
                    method process_mgr = process_mgr
                  end in
                  Team_session_engine_eio.recover_running_sessions ~sw ~env
                    ~config:state.Mcp_server.room_config );
          ("chain_bootstrap", fun () -> bootstrap_chain_state state);
          ("telemetry_warmup", fun () -> warm_tool_registry_from_telemetry state);
          ("tool_metrics_restore", fun () -> restore_tool_metrics_from_disk state);
          ("legacy_dir_migration", fun () -> migrate_legacy_dirs state);
          ("jsonl_prune", fun () -> startup_prune_jsonl state);
          ( "keeper_checkpoint_prune",
            fun () -> startup_prune_keeper_checkpoints state );
          (* keeper_bootstrap removed: keeper_autoboot subsystem in
             start_keeper_loops handles this in a dedicated fiber,
             avoiding PG pool contention with dashboard refresh loops. *)
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
                 "PG init timed out after %.0fs with MASC_STORAGE_TYPE=postgres"
                 pg_init_timeout
             in
             Log.Server.error "%s" reason;
             raise (Invalid_argument reason))
        else
          init_state_blocking ()
      in
      server_state := Some state;
      Server_startup_state.mark_state_ready
        ~backend_mode:(Room.backend_name state.room_config);
      let resolved_base, masc_dir =
        Server_bootstrap_loops.start_background_maintenance ~sw ~clock ~env state
      in
      Server_bootstrap_http.print_startup_banner ~config ~resolved_base ~base_path ~masc_dir;
      (* Create Executor_pool for CPU-heavy dashboard compute.
         Runs in separate OS domains, bypassing fiber contention. *)
      let exec_pool = Eio.Executor_pool.create ~sw ~domain_count:2 domain_mgr in
      Server_dashboard_http.set_executor_pool exec_pool;
      Log.Server.info "Executor_pool created (2 domains) for dashboard";
      (* Start auxiliary transports before optional warmups and keeper loops.
         Otherwise HTTP can report ready while gRPC/WS startup is still stuck
         behind heavier startup work. *)
      (* gRPC coordination transport (default-on, opt-out via MASC_GRPC_ENABLED=0) *)
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
      (* Initialize gRPC client for keeper heartbeat when transport is gRPC *)
      (match Masc_grpc_transport.from_env () with
       | Masc_grpc_transport.Grpc ->
           (try
              let client = Masc_grpc_client.create_from_env ~sw ~env in
              Keeper_keepalive.set_grpc_client ~env client;
              Log.Server.info "gRPC keeper client initialized"
            with exn ->
              Log.Server.warn "gRPC keeper client init failed: %s"
                (Printexc.to_string exn))
       | _ -> ());
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
      (* Cold-start warm-cache stagger is handled by warm_delay_s in each
         Proactive_refresh config. Heavy surfaces delay their initial warm
         compute to avoid concurrent CPU/PG contention.  Lightweight surfaces
         (cp-summary, execution, transport_health) start immediately. *)
      Server_command_plane_http_support.start_cp_summary_refresh_loop ~state ~sw ~clock;
      Server_command_plane_http_support.start_cp_snapshot_refresh_loop ~state ~sw ~clock;
      Server_dashboard_http.start_execution_refresh_loop ~state ~sw ~clock ~net ~mono_clock;
      Server_dashboard_http.start_transport_health_refresh_loop ~state ~sw ~clock;
      Server_dashboard_http.start_mission_refresh_loop ~state ~sw ~clock;
      Server_dashboard_http.start_operator_snapshot_refresh_loop ~state ~sw ~clock;
      Server_dashboard_http.start_operator_digest_refresh_loop ~state ~sw ~clock;
      (* Pre-warm shell cache in a separate fiber so it cannot block
         keeper loop startup or lazy tasks (#keeper-bootstrap-stuck). *)
      Eio.Fiber.fork ~sw (fun () ->
        (try
           match Eio.Time.with_timeout clock 10.0 (fun () ->
             Server_dashboard_http.warm_shell_cache state;
             Ok ())
           with
           | Ok () -> ()
           | Error `Timeout ->
             Log.Dashboard.warn "shell cache pre-warm timed out (10s)"
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Dashboard.warn "shell cache pre-warm failed: %s"
             (Printexc.to_string exn)));
      Server_bootstrap_loops.start_keeper_loops ~sw ~clock ~net ~domain_mgr ~proc_mgr state;
      start_lazy_startup state
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Server_startup_state.mark_degraded ~error:(Printexc.to_string exn);
      Log.Server.error "Background init failed (HTTP still serving): %s"
        (Printexc.to_string exn);
      if String.equal initial_backend_mode "postgres-native" then
        exit 1);

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
