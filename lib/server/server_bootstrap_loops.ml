(** Server_bootstrap_loops — Resident loops and background maintenance.

    Extracted from Server_runtime_bootstrap to isolate the large
    subsystem-spawning functions into a focused module. *)

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
  let keeper_lifecycle_sub =
    Agent_sdk.Event_bus.subscribe event_bus
      ~filter:(function
        | Agent_sdk.Event_bus.Custom ("masc:keeper:resident_lifecycle", _) -> true
        | _ -> false)
  in
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      (try
        let events = Agent_sdk.Event_bus.drain keeper_lifecycle_sub in
        List.iter
          (function
            | Agent_sdk.Event_bus.Custom ("masc:keeper:resident_lifecycle", payload) ->
                (match
                   ( Safe_ops.json_string_opt "event" payload,
                     Safe_ops.json_string_opt "keeper_name" payload )
                 with
                | Some event, Some keeper_name ->
                    Server_dashboard_http.patch_keeper_dependent_caches
                      ~keeper_name ~event
                | _ -> ())
            | _ -> ())
          events;
        if events <> [] then
          Log.Dashboard.info
            "patched keeper-dependent dashboard caches (%d lifecycle event(s))"
            (List.length events)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Dashboard.error "keeper lifecycle listener iteration failed: %s"
          (Printexc.to_string exn));
      Eio.Time.sleep clock 0.25;
      loop ()
    in
    loop ());
  (* Inject Event_bus into keeper resident runtime for telemetry publishing *)
  Keeper_keepalive.set_bus event_bus;
  Board_dispatch.set_keeper_board_signal_hook (fun signal ->
    Keeper_keepalive.wakeup_relevant_keeper_for_board_signal
      ~config:state.room_config
      signal);
  (* Wire broadcast → keeper wakeup: any broadcast wakes keepers so they
     can react to new tasks, mentions, or room activity immediately. *)
  Room_eio.on_broadcast_mention := (fun mention ->
    match mention with
    | Some target ->
        Keeper_keepalive.wakeup_keeper target;
        Log.Keeper.info "broadcast mention → wakeup keeper %s" target
    | None ->
        Keeper_keepalive.wakeup_all_keepers ();
        Log.Keeper.info "broadcast → wakeup all keepers (reactive push)");
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
  (* Auto-boot keepers: read .masc/resident-keepers/*.json,
     load each keeper's meta, and start keepalive loops. *)
  fork_subsystem "keeper_autoboot" (fun () ->
    if not Env_config.KeeperBootstrap.enabled then
      Log.Keeper.info "autoboot: disabled via MASC_KEEPER_BOOTSTRAP_ENABLED=false"
    else begin
    (* Brief delay so other subsystems (SSE, board, orchestrator) settle first. *)
    Eio.Time.sleep clock 5.0;
    let config = state.room_config in
    let entries = Keeper_types.list_resident_keepers config in
    let booted = ref 0 in
    List.iter (fun (entry : Keeper_types.keeper_boot_entry) ->
        try
          match Keeper_runtime.ensure_keeper_meta config entry.name with
          | Error e ->
            Log.Keeper.error "autoboot: failed to load meta for %s: %s" entry.name e
          | Ok m ->
            if not m.presence_keepalive then
              Log.Keeper.info "autoboot: skipping %s (presence_keepalive=false)" entry.name
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
          Log.Keeper.error "autoboot: exception for %s: %s" entry.name
            (Printexc.to_string exn)
    ) entries;
    Log.Keeper.info "autoboot: %d/%d keepers started"
      !booted (List.length entries)
    end);
  (* Phase 5: unified startup subsystem summary *)
  Log.info ~ctx:"startup" "subsystems: resident loops started"

let start_background_maintenance ~sw ~clock (state : Mcp_server.server_state) =
  (* Metrics flush fiber: drains write queue every 500ms, batches file appends.
     Replaces the old mutex + synchronous file I/O pattern. *)
  Eio.Fiber.fork ~sw (fun () ->
    try Metrics_store_eio.start_flush_fiber ~clock
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Server.error "metrics_flush fiber crashed: %s"
        (Printexc.to_string exn));
  Shutdown.register ~name:"metrics_flush" ~priority:30 Metrics_store_eio.flush_pending;
  (* Tool metrics JSONL persistence: flush buffered records to disk periodically.
     Also registers a post-hook so every tool call is enqueued for persistence. *)
  Tool_dispatch.register_post_hook (fun result ->
    Tool_metrics_persist.enqueue result;
    result);
  Tool_metrics_persist.start_flush_fiber ~sw ~clock
    ~base_path:state.room_config.base_path;
  (match Board_dispatch.get_pg_pool () with
  | Some pool ->
      let listener = Board_listener.create pool in
      Eio.Fiber.fork ~sw (fun () ->
        try Board_listener.start ~clock listener
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.BoardListener.error "board listener fiber crashed: %s"
            (Printexc.to_string exn));
      Log.BoardListener.info "Fiber started for real-time Board events"
  | None ->
      Log.BoardListener.info "Skipped (not using PostgreSQL backend)");
  Eio.Fiber.fork ~sw (fun () ->
      let rec loop () =
        Eio.Time.sleep clock 60.0;
        (try
          let stale_sids = Sse.cleanup_stale () in
          List.iter Server_routes_http_common.stop_sse_session stale_sids;
          if stale_sids <> [] then
            Log.Server.info "Reaped %d stale connections (active: %d)"
              (List.length stale_sids) (Sse.client_count ());
          let evicted_events = Sse.cleanup_expired_events () in
          if evicted_events > 0 then
            Log.Server.info "Evicted %d expired SSE buffer events" evicted_events;
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
          let ext_reaped = Sse.reap_dead_external_subscribers () in
          if ext_reaped > 0 then
            Log.Server.info "reaped %d dead external subscribers" ext_reaped;
          if Server_webrtc_transport.is_enabled () then begin
            let webrtc_expired = Server_webrtc_transport.cleanup_expired_offers () in
            if webrtc_expired > 0 then
              Log.Server.info "WebRTC: cleaned %d expired offers" webrtc_expired
          end
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Server.error "cleanup loop iteration failed: %s"
            (Printexc.to_string exn));
        loop ()
      in
      loop ());
  let resolved_base = state.room_config.base_path in
  let masc_dir = Room.masc_root_dir state.room_config in
  A2a_tools.init ~masc_dir;
  (resolved_base, masc_dir)
