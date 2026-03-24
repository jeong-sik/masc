
open Server_auth
open Server_routes_http

module Http = Http_server_eio
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

let existing_dir path =
  Sys.file_exists path && Sys.is_directory path

let dedupe_keep_order values =
  let rec loop acc = function
    | [] -> List.rev acc
    | value :: rest ->
        if List.mem value acc then loop acc rest
        else loop (value :: acc) rest
  in
  loop [] values

let prompt_markdown_dir_candidates ~workspace_path ~base_path =
  let workspace_candidate =
    Filename.concat workspace_path "config/prompts"
  in
  let base_candidate = Filename.concat base_path "config/prompts" in
  let cwd_candidate = Filename.concat (Sys.getcwd ()) "config/prompts" in
  let exe_candidate =
    let exe_dir = Filename.dirname Sys.executable_name in
    let root = Filename.dirname (Filename.dirname (Filename.dirname exe_dir)) in
    Filename.concat root "config/prompts"
  in
  let dune_candidate =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root when String.trim root <> "" ->
        Some (Filename.concat root "config/prompts")
    | _ -> None
  in
  let candidates =
    workspace_candidate
    :: base_candidate
    :: (match dune_candidate with Some dir -> [ dir ] | None -> [])
    @ [ exe_candidate; cwd_candidate ]
  in
  dedupe_keep_order candidates

let resolve_prompt_markdown_dir ~workspace_path ~base_path =
  let candidates = prompt_markdown_dir_candidates ~workspace_path ~base_path in
  match List.find_opt existing_dir candidates with
  | Some dir -> dir
  | None -> Filename.concat base_path "config/prompts"

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
    resolve_prompt_markdown_dir
      ~workspace_path:state.room_config.workspace_path
      ~base_path:state.room_config.base_path
  in
  Prompt_registry.set_markdown_dir prompt_markdown_dir;
  if prompt_markdown_dir
     <> Filename.concat state.room_config.workspace_path "config/prompts"
  then
    Log.Misc.info "prompt markdown dir resolved outside room base: %s"
      prompt_markdown_dir;
  Prompt_defaults.init ();
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
  (try Prompt_registry.restore_overrides state.room_config.workspace_path
   with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
     Log.Misc.error "prompt override restore failed: %s"
       (Printexc.to_string exn));
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
  | Some _ ->
      Log.Server.info "PG shared pool available"
  | None ->
      Log.Server.info "No PG pool available"

let init_memory_pg_schema () =
  match Board_dispatch.get_pg_pool () with
  | Some pool -> (
      match Memory_pg.ensure_schema pool with
      | Ok () -> ()
      | Error msg ->
          Log.MemoryPg.error "Schema init failed: %s (long_term_backend will use no-op)" msg)
  | None ->
      Log.MemoryPg.info "No PG pool available; long_term_backend will use JSONL fallback"

let install_tooling ~governance_level (state : Mcp_server.server_state) =
  Governance_pipeline.install ~config:state.room_config ~governance_level;
  Tool_permissions.install ~get_agent_name:(fun () -> None)

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
  (* Wire broadcast → keeper wakeup: when a broadcast mentions a keeper,
     interrupt its sleep so it processes the mention immediately. *)
  Room_eio.on_broadcast_mention := (fun mention ->
    match mention with
    | Some target ->
        Keeper_keepalive.wakeup_keeper target;
        Log.Keeper.info "broadcast mention → wakeup keeper %s" target
    | None ->
        (* No specific mention — no targeted wakeup needed.
           Keepers will see it on next heartbeat via board events. *)
        ());
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
  (* Build read-only tool surface shared by both judges. *)
  let judge_tool_names =
    [ "masc_status"; "masc_tasks"; "masc_agents"; "masc_board_list" ]
  in
  let judge_masc_tools =
    match
      Agent_tool_surfaces.local_worker_tool_schemas ~names:judge_tool_names ()
    with
    | Ok schemas -> schemas
    | Error _ -> []
  in
  let judge_dispatch ~(name : string) ~(args : Yojson.Safe.t) : bool * string =
    let config = state.room_config in
    let agent_name = "operator-judge" in
    let ctx_room : Tool_room.context = { config; agent_name } in
    let ctx_task : Tool_task.context = { config; agent_name } in
    let ctx_agent : Tool_agent.context = { config; agent_name } in
    match name with
    | "masc_status" -> (
        match Tool_room.dispatch ctx_room ~name ~args with
        | Some result -> result
        | None -> (false, "masc_status: dispatch failed"))
    | "masc_tasks" -> (
        match Tool_task.dispatch ctx_task ~name ~args with
        | Some result -> result
        | None -> (false, "masc_tasks: dispatch failed"))
    | "masc_agents" -> (
        match Tool_agent.dispatch ctx_agent ~name ~args with
        | Some result -> result
        | None -> (false, "masc_agents: dispatch failed"))
    | "masc_board_list" ->
        Tool_board.handle_tool name args
    | _ -> (false, Printf.sprintf "judge: tool '%s' not allowed" name)
  in
  fork_subsystem "governance_judge" (fun () ->
    Dashboard_governance_judge.start ~sw ~clock
      ~base_path:state.room_config.base_path
      ~masc_tools:judge_masc_tools ~dispatch:judge_dispatch
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
      ~masc_tools:judge_masc_tools ~dispatch:judge_dispatch
      ~build_facts:(fun () ->
        Operator_control.snapshot_json ~actor:"operator-judge" ~view:"summary"
          ~include_messages:false ~include_keepers:false operator_judge_ctx)
      ());
  fork_subsystem "session_cleanup" (fun () ->
    Session.start_mcp_session_cleanup_loop ~sw ~clock ());
  (* Auto-boot resident keepers: read .masc/resident-keepers/*.json,
     load or parse each keeper's meta, and start keepalive loops. *)
  fork_subsystem "keeper_autoboot" (fun () ->
    if not Env_config.KeeperBootstrap.enabled then
      Log.Keeper.info "autoboot: disabled via MASC_KEEPER_BOOTSTRAP_ENABLED=false"
    else begin
    (* Brief delay so other subsystems (SSE, board, orchestrator) settle first. *)
    Eio.Time.sleep clock 5.0;
    let config = state.room_config in
    let specs = Keeper_types.list_resident_keepers config in
    let booted = ref 0 in
    List.iter (fun (spec : Keeper_types.resident_keeper_spec) ->
      if not spec.desired then
        Log.Keeper.info "autoboot: skipping %s (desired=false)" spec.name
      else
        try
          (* Prefer persisted meta on disk; fall back to seed_meta from resident spec. *)
          let meta =
            match Keeper_types.read_meta config spec.name with
            | Ok (Some m) -> Ok m
            | Ok None -> Keeper_types.meta_of_json spec.seed_meta
            | Error e -> Error e
          in
          match meta with
          | Error e ->
            Log.Keeper.error "autoboot: failed to load meta for %s: %s" spec.name e
          | Ok m ->
            if not m.presence_keepalive then
              Log.Keeper.info "autoboot: skipping %s (presence_keepalive=false)" spec.name
            else begin
              let ctx : _ Keeper_types.context = {
                config;
                agent_name = m.agent_name;
                sw;
                clock;
                proc_mgr = Some proc_mgr;
              } in
              Keeper_keepalive.start_keepalive ~proactive_warmup_sec:60 ctx m;
              incr booted;
              Log.Keeper.info "autoboot: started keepalive for %s" m.name
            end
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Keeper.error "autoboot: exception for %s: %s" spec.name
            (Printexc.to_string exn)
    ) specs;
    Log.Keeper.info "autoboot: %d/%d resident keepers started"
      !booted (List.length specs)
    end);
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
        (* Reap dead external subscribers (gRPC, WebSocket, etc.)
           that remain registered after their transport connection drops.
           Without this, stale subscribers accumulate when no broadcasts
           occur to trigger the lazy is_alive check. *)
        let ext_reaped = Sse.reap_dead_external_subscribers () in
        if ext_reaped > 0 then
          Log.Server.info "reaped %d dead external subscribers" ext_reaped;
        (* Clean up expired WebRTC signaling offers.
           Offers older than 60s are removed to prevent indefinite
           accumulation from failed handshake attempts. *)
        if Server_webrtc_transport.is_enabled () then begin
          let webrtc_expired = Server_webrtc_transport.cleanup_expired_offers () in
          if webrtc_expired > 0 then
            Log.Server.info "WebRTC: cleaned %d expired offers" webrtc_expired
        end;
        loop ()
      in
      loop ());
  let resolved_base = state.room_config.base_path in
  let masc_dir = Room.masc_root_dir state.room_config in
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
  Printf.printf "   GET  /health → Health check\n%!";
  if Masc_grpc_server.is_enabled () then
    Printf.printf
      "   gRPC :%d → Coordination + grpc.health.v1.Health + reflection\n%!"
      (Masc_grpc_server.configured_port ());
  if Server_ws_standalone.is_enabled () then
    Printf.printf
      "   GET  /ws → WebSocket discovery (standalone ws://127.0.0.1:%d/)\n%!"
      (Server_ws_standalone.configured_port ());
  if Server_webrtc_transport.is_enabled () then
    Printf.printf
      "   POST /webrtc/offer, /webrtc/answer → WebRTC signaling\n%!"

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

(** Accept loop with automatic HTTP/1.1 vs HTTP/2 detection.
    Each connection is peeked (MSG_PEEK) to inspect the first bytes
    before dispatching to httpun-eio or h2-eio.  The peek is
    non-destructive, so both libraries read the socket normally. *)
let serve_auto ~sw ~clock ~socket ~request_handler ~h2_request_handler
    ~h2_error_handler =
  let is_cancelled exn =
    match exn with
    | Eio.Cancel.Cancelled _ -> true
    | _ -> false
  in
  Log.Server.info "HTTP auto-detect mode: HTTP/1.1 + HTTP/2 h2c on same port";
  let h2_count = Atomic.make 0 in
  let h1_count = Atomic.make 0 in
  let stats_logged = Atomic.make false in
  let rec accept_loop backoff_s =
    try
      let flow, client_addr = Eio.Net.accept ~sw socket in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Switch.run (fun conn_sw ->
              Eio.Switch.on_release conn_sw (fun () ->
                  try Eio.Flow.close flow
                  with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn ->
                    Log.Misc.warn "[auto] flow close: %s"
                      (Printexc.to_string exn));
              try
                match Http_protocol_detect.detect flow with
                | Ok Http_protocol_detect.Http2 ->
                  ignore (Atomic.fetch_and_add h2_count 1);
                  H2_eio.Server.create_connection_handler ~sw:conn_sw
                    ~request_handler:h2_request_handler
                    ~error_handler:h2_error_handler
                    client_addr
                    flow
                | Ok Http_protocol_detect.Http1 ->
                  ignore (Atomic.fetch_and_add h1_count 1);
                  let conn_handler =
                    Httpun_eio.Server.create_connection_handler ~sw:conn_sw
                      ~request_handler:(fun client_addr ->
                        request_handler client_addr)
                      ~error_handler:
                        (fun _client_addr ?request:_ error respond ->
                        let msg =
                          match error with
                          | `Exn exn -> Printexc.to_string exn
                          | `Bad_request -> "Bad request"
                          | `Bad_gateway -> "Bad gateway"
                          | `Internal_server_error -> "Internal server error"
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
                | Error msg ->
                  Log.Misc.debug "[auto] protocol detect skipped: %s" msg
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Misc.error "[auto] Connection error: %s"
                  (Printexc.to_string exn)));
      accept_loop 0.05
    with
    | Eio.Cancel.Cancelled _ as e ->
      if Atomic.compare_and_set stats_logged false true then
        Log.Server.info "[auto] stats: h2=%d h1=%d"
          (Atomic.get h2_count) (Atomic.get h1_count);
      raise e
    | exn ->
      if is_cancelled exn then begin
        if Atomic.compare_and_set stats_logged false true then
          Log.Server.info "[auto] stats: h2=%d h1=%d"
            (Atomic.get h2_count) (Atomic.get h1_count)
      end
      else begin
        Log.Misc.error "[auto] Accept error: %s" (Printexc.to_string exn);
        (try Eio.Time.sleep clock backoff_s
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Misc.warn "[auto] backoff sleep: %s"
             (Printexc.to_string exn));
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
  let config = make_http_config ~host ~port in
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
  let socket = listen_socket ~sw ~net config in
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
      let state =
        create_server_state ~sw ~base_path ~clock ~mono_clock ~net ~proc_mgr ~fs
      in
      bootstrap_server_state_blocking state;
      install_tooling ~governance_level state;
      init_task_backend ();
      inject_shared_pg_pool ();
      init_memory_pg_schema ();
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
              Team_session_engine_eio.recover_running_sessions ~sw ~clock
                ~config:state.Mcp_server.room_config );
          ("chain_bootstrap", fun () -> bootstrap_chain_state state);
          ("telemetry_warmup", fun () -> warm_tool_registry_from_telemetry state);
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
        Safe_ops.get_env_float_logged "MASC_PG_INIT_TIMEOUT_SEC" ~default:10.0
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
        start_background_maintenance ~sw ~clock state
      in
      print_startup_banner ~config ~resolved_base ~base_path ~masc_dir;
      (* Create Executor_pool for CPU-heavy dashboard compute.
         Runs in separate OS domains, bypassing fiber contention. *)
      let exec_pool = Eio.Executor_pool.create ~sw ~domain_count:2 domain_mgr in
      Server_dashboard_http.set_executor_pool exec_pool;
      Log.Server.info "Executor_pool created (2 domains) for dashboard";
      Server_command_plane_http_support.start_cp_summary_refresh_loop ~state ~sw ~clock;
      Server_command_plane_http_support.start_cp_snapshot_refresh_loop ~state ~sw ~clock;
      Server_dashboard_http.start_execution_refresh_loop ~state ~sw ~clock ~net ~mono_clock;
      Server_dashboard_http.start_mission_refresh_loop ~state ~sw ~clock;
      Server_dashboard_http.start_operator_snapshot_refresh_loop ~state ~sw ~clock;
      Server_dashboard_http.start_operator_digest_refresh_loop ~state ~sw ~clock;
      (* Pre-warm shell cache so the first /dashboard load is instant.
         shell is the only room-truth component without a proactive refresh loop. *)
      Server_dashboard_http.warm_shell_cache state;
      start_resident_loops ~sw ~clock ~net ~domain_mgr ~proc_mgr state;
      start_lazy_startup state;
      (* gRPC coordination transport (opt-in via MASC_GRPC_ENABLED=1) *)
      let tool_dispatcher tool_name args_json =
        let arguments =
          try Yojson.Safe.from_string args_json
          with _ -> `Assoc []
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
            Server_webrtc_transport.start_webrtc_connection ~sw ~env peer_id))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Server_startup_state.mark_degraded ~error:(Printexc.to_string exn);
      Log.Server.error "Background init failed (HTTP still serving): %s"
        (Printexc.to_string exn));

  (* 3. Start serving -- /health responds before init completes *)
  match http_mode with
  | `H2_only ->
    serve_h2 ~sw ~clock ~socket ~h2_request_handler ~h2_error_handler
  | `H1_only ->
    serve ~sw ~clock ~socket ~request_handler
  | `Auto ->
    serve_auto ~sw ~clock ~socket ~request_handler ~h2_request_handler
      ~h2_error_handler
