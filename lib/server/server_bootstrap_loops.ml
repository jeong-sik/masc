(** Server_bootstrap_loops — Keeper loops and background maintenance.

    Extracted from Server_runtime_bootstrap to isolate the large
    subsystem-spawning functions into a focused module. *)

let install_tooling ~governance_level (state : Mcp_server.server_state) =
  Governance_pipeline.install ~config:state.room_config ~governance_level

let start_keeper_loops ~sw ~clock ~net ~domain_mgr ~proc_mgr
    (state : Mcp_server.server_state) =
  Progress.set_sse_callback Sse.broadcast;
  Sse.set_clock clock;
  (* Wire stop_keeper hook so zombie GC can terminate keeper fibers *)
  Coord_hooks.stop_keeper_fn := Keeper_keepalive.stop_keepalive;
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
  let wait_for_lazy_startup () =
    let rec loop last_log_at =
      let pending = Server_startup_state.pending_lazy_tasks () in
      if pending = [] then ()
      else begin
        let now = Eio.Time.now clock in
        let last_log_at =
          if now -. last_log_at >= 5.0 then begin
            Log.Keeper.info
              "autoboot: waiting for lazy startup tasks to finish before keeper boot [%s]"
              (String.concat ", " pending);
            now
          end else
            last_log_at
        in
        Eio.Time.sleep clock 0.25;
        loop last_log_at
      end
    in
    loop (Eio.Time.now clock)
  in
  (* Event_bus → SSE bridge: relay masc:* events to dashboard *)
  Oas_sse_bridge.start ~sw ~clock ~config:state.room_config ~bus:event_bus;
  let keeper_lifecycle_sub =
    Agent_sdk.Event_bus.subscribe event_bus
      ~filter:(fun (evt : Agent_sdk.Event_bus.event) ->
        match evt.payload with
        | Agent_sdk.Event_bus.Custom ("masc:keeper:lifecycle", _) -> true
        | _ -> false)
  in
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      (try
        let events = Agent_sdk.Event_bus.drain keeper_lifecycle_sub in
        List.iter
          (fun (evt : Agent_sdk.Event_bus.event) ->
            match evt.payload with
            | Agent_sdk.Event_bus.Custom ("masc:keeper:lifecycle", payload) ->
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
        if events <> [] then begin
          Log.Dashboard.info
            "patched keeper-dependent dashboard caches (%d lifecycle event(s))"
            (List.length events);
          Server_dashboard_http.broadcast_namespace_truth_snapshot state
        end
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Dashboard.error "keeper lifecycle listener iteration failed: %s"
          (Printexc.to_string exn));
      Eio.Time.sleep clock 0.25;
      loop ()
    in
    loop ());
  (* Inject Event_bus into keeper keepalive runtime for telemetry publishing *)
  Keeper_keepalive.set_bus event_bus;
  Board_dispatch.set_keeper_board_signal_hook (fun signal ->
    Keeper_keepalive.wakeup_relevant_keeper_for_board_signal
      ~config:state.room_config
      signal);
  Board_dispatch.set_board_sse_hook (fun event ->
    let params = match event with
      | Board_dispatch.Post_created { post_id; author; title; content; hearth } ->
          let preview =
            if String.length content > 200 then String.sub content 0 200
            else content
          in
          let base = [("type", `String "post_created");
                      ("post_id", `String post_id);
                      ("author", `String author);
                      ("title", `String title);
                      ("content", `String preview)] in
          `Assoc (match hearth with
                  | Some h -> ("hearth", `String h) :: base
                  | None -> base)
      | Board_dispatch.Comment_added { post_id; comment_id; author } ->
          `Assoc [("type", `String "comment_added");
                  ("post_id", `String post_id);
                  ("comment_id", `String comment_id);
                  ("author", `String author)]
      | Board_dispatch.Post_voted { post_id; voter; direction } ->
          let dir = match direction with Board.Up -> "up" | Board.Down -> "down" in
          `Assoc [("type", `String "post_voted");
                  ("post_id", `String post_id);
                  ("voter", `String voter);
                  ("direction", `String dir)]
      | Board_dispatch.Comment_voted { comment_id; voter; direction } ->
          let dir = match direction with Board.Up -> "up" | Board.Down -> "down" in
          `Assoc [("type", `String "comment_voted");
                  ("comment_id", `String comment_id);
                  ("voter", `String voter);
                  ("direction", `String dir)]
    in
    Sse.broadcast (`Assoc [
      ("jsonrpc", `String "2.0");
      ("method", `String "notifications/board");
      ("params", params)
    ]);
    (* Emit activity event so Discord/external connectors can detect board posts *)
    let activity_kind, activity_actor, activity_subject, activity_payload = match event with
      | Board_dispatch.Post_created { post_id; author; title; content; hearth } ->
          let base = [("post_id", `String post_id); ("title", `String title);
                      ("content", `String content); ("author", `String author)] in
          let payload_fields = match hearth with
            | Some h -> ("hearth", `String h) :: base
            | None -> base
          in
          ("board.posted",
           Activity_graph.entity ~kind:"agent" author,
           Some (Activity_graph.entity ~kind:"post" post_id),
           `Assoc payload_fields)
      | Board_dispatch.Comment_added { post_id; comment_id; author } ->
          ("board.commented",
           Activity_graph.entity ~kind:"agent" author,
           Some (Activity_graph.entity ~kind:"post" post_id),
           `Assoc [("post_id", `String post_id); ("comment_id", `String comment_id);
                   ("author", `String author)])
      | Board_dispatch.Post_voted { post_id; voter; direction } ->
          let dir = match direction with Board.Up -> "up" | Board.Down -> "down" in
          ("board.voted",
           Activity_graph.entity ~kind:"agent" voter,
           Some (Activity_graph.entity ~kind:"post" post_id),
           `Assoc [("post_id", `String post_id); ("direction", `String dir)])
      | Board_dispatch.Comment_voted { comment_id; voter; direction } ->
          let dir = match direction with Board.Up -> "up" | Board.Down -> "down" in
          ("board.voted",
           Activity_graph.entity ~kind:"agent" voter,
           Some (Activity_graph.entity ~kind:"comment" comment_id),
           `Assoc [("comment_id", `String comment_id); ("direction", `String dir)])
    in
    ignore (Activity_graph.emit state.room_config
      ~actor:activity_actor ?subject:activity_subject
      ~kind:activity_kind ~payload:activity_payload
      ~tags:["board"; activity_kind] ()));
  (* Wire broadcast → keeper wakeup: any broadcast wakes keepers so they
     can react to new tasks, mentions, or room activity immediately.
     Coord_state.on_broadcast_mention is the active path (Coord.broadcast uses
     Coord_state.broadcast); Coord_eio.on_broadcast_mention is kept in sync as
     a safety net for any legacy callers. *)
  let broadcast_mention_handler = (fun mention ->
    match mention with
    | Some target ->
        Keeper_keepalive.wakeup_keeper
          ~base_path:state.room_config.base_path target;
        Log.Keeper.info "broadcast mention → wakeup keeper %s" target
    | None ->
        Keeper_keepalive.wakeup_all_keepers
          ~base_path:state.room_config.base_path ();
        Log.Keeper.info "broadcast → wakeup all keepers (reactive push)") in
  Coord_broadcast.on_broadcast_mention := broadcast_mention_handler;
  Coord_eio.on_broadcast_mention := broadcast_mention_handler;
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
  let make_judge_dispatch ~actor ~(name : string) ~(args : Yojson.Safe.t)
      : bool * string =
    let config = state.room_config in
    let agent_name = actor in
    let ctx_room : Tool_coord.context = { config; agent_name } in
    let ctx_task : Tool_task.context = { config; agent_name; sw = Some sw } in
    let ctx_agent : Tool_agent.context = { config; agent_name } in
    match name with
    | "masc_status" -> (
        match Tool_coord.dispatch ctx_room ~name ~args with
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
  let governance_judge_dispatch = make_judge_dispatch ~actor:"governance-judge" in
  let operator_judge_dispatch = make_judge_dispatch ~actor:"operator-judge" in
  fork_subsystem "governance_judge" (fun () ->
    Dashboard_governance_judge.start ~sw ~clock ~net
      ~base_path:state.room_config.base_path
      ~masc_tools:judge_masc_tools ~dispatch:governance_judge_dispatch
      ~build_facts:(fun () ->
        let base = Dashboard_governance.factual_snapshot_json
          ~base_path:state.room_config.base_path in
        let agents = Coord.get_agents_status state.room_config in
        Operator_control_snapshot.merge_json_objects base
          (`Assoc [("agents", agents)]))
      ());
  fork_subsystem "operator_judge" (fun () ->
    let operator_judge_ctx : _ Operator_control.context =
      {
        config = state.room_config;
        agent_name = "operator-judge";
        sw;
        clock;
        proc_mgr = Some proc_mgr;
        net = state.net;
        mcp_session_id = None;
      }
    in
    Dashboard_operator_judge.start ~sw ~clock ~net ~config:state.room_config
      ~masc_tools:judge_masc_tools ~dispatch:operator_judge_dispatch
      ~build_facts:(fun () ->
        Operator_control.snapshot_json ~actor:"operator-judge" ~view:"summary"
          ~include_messages:false ~include_keepers:false operator_judge_ctx)
      ());
  fork_subsystem "session_cleanup" (fun () ->
    Session.start_mcp_session_cleanup_loop ~sw ~clock ());
  (* Auto-boot keepers from keeper meta and start keepalive loops.
     Retries unbooted keepers up to [max_retries] times so transient
     failures (model resolution, discovery timing) don't permanently
     block keeper startup.  See #5717. *)
  fork_subsystem "keeper_autoboot" (fun () ->
    if not Env_config.KeeperBootstrap.enabled then
      Log.Keeper.info "autoboot: disabled via MASC_KEEPER_BOOTSTRAP_ENABLED=false"
    else begin
      wait_for_lazy_startup ();
      Log.Keeper.info "autoboot: lazy startup complete; keeper bootstrap will start last";
      (* Brief delay so other subsystems (SSE, board, orchestrator) settle first. *)
      Eio.Time.sleep clock 5.0;
      let config = state.room_config in
      let masc_root = Coord.masc_root_dir config in
      let keeper_dir = Keeper_fs.keeper_dir config in
      let all_names = Keeper_types.keeper_names config in
      let all_count = List.length all_names in
      Log.Keeper.info
        "autoboot: base_path=%s masc_root=%s keeper_dir=%s keeper_json_count=%d"
        config.base_path masc_root keeper_dir all_count;
      let names = Keeper_runtime.bootable_keeper_names config in
      let keeper_boot_ctx : _ Keeper_types.context = {
        config;
        agent_name = "keeper-autoboot";
        sw;
        clock;
        proc_mgr = Some proc_mgr;
        net = state.net;
      } in
      Log.Keeper.info
        "autoboot: %d keeper(s) to boot; concurrent keeper turns throttled to %d via MASC_KEEPER_AUTOBOOT_MAX"
        (List.length names) Keeper_keepalive.keeper_turn_throttle_limit;
      Log.Keeper.info "autoboot: keeper set [%s]" (String.concat ", " names);
      let base_warmup = Keeper_config.keeper_bootstrap_proactive_warmup_sec () in
      let stagger_step = Keeper_config.keeper_bootstrap_stagger_step_sec () in
      (* Attempt to boot a single keeper. Returns true if started. *)
      let try_boot_one idx name =
        try
          Log.Keeper.info "autoboot: loading meta for %s" name;
          match Keeper_runtime.load_or_materialize_boot_meta keeper_boot_ctx name with
          | Error e ->
            Log.Keeper.error "autoboot: failed to load meta for %s: %s" name e;
            false
          | Ok { meta = m; materialized } ->
            if Keeper_registry.is_running ~base_path:config.base_path m.name then (
              Log.Keeper.info
                "autoboot: %s already running%s"
                m.name
                (if materialized then " (materialized from TOML)" else "");
              true
            ) else begin
              let warmup = base_warmup + (idx * stagger_step) in
              Log.Keeper.info "autoboot: calling start_keepalive for %s (warmup=%ds)"
                name warmup;
              let ctx : _ Keeper_types.context = {
                config;
                agent_name = m.agent_name;
                sw;
                clock;
                proc_mgr = Some proc_mgr;
                net = state.net;
              } in
              Keeper_keepalive.start_keepalive ~proactive_warmup_sec:warmup ctx m;
              let running = Keeper_registry.is_running ~base_path:config.base_path m.name in
              if running then
                Log.Keeper.info "autoboot: started keepalive for %s" m.name
              else
                Log.Keeper.warn "autoboot: start_keepalive returned but %s not in registry" m.name;
              running
            end
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Keeper.error "autoboot: exception for %s: %s" name
            (Printexc.to_string exn);
          false
      in
      (* Initial boot pass *)
      let booted = List.filteri (fun idx name -> try_boot_one idx name) names in
      let booted_count = List.length booted in
      let total = List.length names in
      Log.Keeper.info "autoboot: initial pass %d/%d keepers started" booted_count total;
      (* Retry loop for keepers that failed initial boot *)
      if booted_count < total then begin
        let max_retries = Keeper_config.keeper_bootstrap_retry_max () in
        let retry_interval_s = Float.of_int (Keeper_config.keeper_bootstrap_retry_interval_sec ()) in
        let rec retry_loop round =
          if round > max_retries then
            Log.Keeper.warn
              "autoboot: gave up after %d retries; %d/%d keepers remain unbooted"
              max_retries
              (total - List.length (List.filter (fun name ->
                Keeper_registry.is_running ~base_path:config.base_path name) names))
              total
          else begin
            Eio.Time.sleep clock retry_interval_s;
            let unbooted = List.filter (fun name ->
              not (Keeper_registry.is_running ~base_path:config.base_path name)
            ) names in
            if unbooted = [] then
              Log.Keeper.info "autoboot: all %d keepers running after %d retry round(s)" total round
            else begin
              Log.Keeper.info "autoboot: retry round %d/%d — %d unbooted: [%s]"
                round max_retries (List.length unbooted) (String.concat ", " unbooted);
              List.iteri (fun idx name -> ignore (try_boot_one idx name)) unbooted;
              retry_loop (round + 1)
            end
          end
        in
        retry_loop 1
      end
    end);
  (* Phase 5: unified startup subsystem summary *)
  Log.info ~ctx:"startup" "subsystems: keeper loops started"

let start_background_maintenance ~sw ~clock ~env (state : Mcp_server.server_state) =
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
  (* Deterministic output budget enforcement: truncate oversized tool outputs
     with structured metadata before metrics/OTEL hooks see them. *)
  Tool_output_validation.install ();
  (* Tool metrics JSONL persistence: flush buffered records to disk periodically.
     The shared post-hook is the canonical write path for persisted tool
     metrics so keeper-internal calls are counted exactly once. *)
  Tool_dispatch.register_post_hook (fun result ->
    Tool_metrics.record result;
    Tool_metrics_persist.enqueue result;
    result);
  Tool_metrics_persist.start_flush_fiber ~sw ~clock
    ~base_path:state.room_config.base_path;
  (* System_internal tool usage log: durable JSONL for pruning evidence (#5120) *)
  Tool_usage_log.init ~base_path:state.room_config.base_path;
  Tool_usage_log.install ();
  (* Keeper tool call I/O log: full input/output for dashboard inspector *)
  Keeper_tool_call_log.init ~base_path:state.room_config.base_path;
  Otel_dispatch_hook.install ();
  Otel_spans.setup_exporter ~sw env;
  Shutdown.register ~name:"otel_exporter" ~priority:20 Otel_spans.shutdown;
  (* Board_listener removed: filesystem-first principle.
     JSONL path emits SSE directly via Board_dispatch.emit_board_sse_event.
     PG path also uses Board_dispatch, making the pg_notify relay redundant. *)
  Eio.Fiber.fork ~sw (fun () ->
      let last_prune = ref (Unix.gettimeofday ()) in
      let rec loop () =
        Eio.Time.sleep clock 60.0;
        (try
          let stale_sids = Sse.cleanup_stale () in
          List.iter Server_routes_http_common.stop_sse_session stale_sids;
          if stale_sids <> [] then
            Log.Server.info "Reaped %d stale connections (active: %d)"
              (List.length stale_sids) (Sse.client_count ());
          let evicted_events = Sse.cleanup_expired_events () in
          if evicted_events > 0 then begin
            (* Same rationale as the namespace-truth broadcast log below:
               when zero SSE clients are attached, the eviction loop is
               garbage-collecting events that nobody would ever replay,
               which is routine housekeeping rather than an
               operator-actionable signal. Emit at INFO only when at
               least one client is on the wire — otherwise DEBUG. *)
            let log_fn =
              if Sse.client_count () > 0
              then Log.Server.info
              else Log.Server.debug
            in
            log_fn "Evicted %d expired SSE buffer events" evicted_events
          end;
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
          Transport_metrics.set_grpc_subscribers
            (Sse.external_subscriber_count_with_prefix "grpc-subscribe-");
          if ext_reaped > 0 then
            Log.Server.info "reaped %d dead external subscribers" ext_reaped;
          if Server_webrtc_transport.is_enabled () then begin
            let webrtc_expired = Server_webrtc_transport.cleanup_expired_offers () in
            if webrtc_expired > 0 then
              Log.Server.info "WebRTC: cleaned %d expired offers" webrtc_expired
          end;
          (* Rate-limit buckets: evict keys unused for 5 minutes *)
          let rl = Eio.Lazy.force Rate_limit.global in
          let rl_reaped = Rate_limit.cleanup rl ~older_than_seconds:300 in
          if rl_reaped > 0 then
            Log.Server.info "Reaped %d stale rate-limit buckets" rl_reaped;
          (* Agent registry: remove resolved-name cache for dead sessions *)
          let ar_reaped = Agent_registry_eio.cleanup_stale_sessions () in
          if ar_reaped > 0 then
            Log.Server.info "Reaped %d stale agent registry sessions" ar_reaped;
          (* A2A: remove heartbeat snapshots for offline agents *)
          let active_agents =
            List.map (fun (id : Agent_identity.t) -> id.agent_name)
              (Agent_registry_eio.list_active ~within_seconds:600.0 ())
          in
          let hb_reaped = A2a_tools.cleanup_stale_heartbeats ~active_agents () in
          if hb_reaped > 0 then
            Log.Server.info "Reaped %d stale heartbeat entries" hb_reaped;
          (* A2A: remove event buffers for dead subscriptions *)
          let buf_reaped = A2a_tools.cleanup_orphan_buffers () in
          if buf_reaped > 0 then
            Log.Server.info "Reaped %d orphan event buffers" buf_reaped;
          (* A2A: expire subscriptions idle > 24h *)
          let sub_expired = A2a_tools.cleanup_stale_subscriptions () in
          if sub_expired > 0 then
            Log.Server.info "Expired %d stale A2A subscriptions" sub_expired;
          (* Periodic JSONL prune: every 24h, clean dated JSONL files *)
          let now = Unix.gettimeofday () in
          if now -. !last_prune >= Masc_time_constants.day then begin
            last_prune := now;
            (try
               let days =
                 Safe_ops.get_env_int_logged "MASC_JSONL_RETENTION_DAYS" ~default:30
               in
               let masc = Coord.masc_dir state.room_config in
               let prune_dir dir =
                 if Sys.file_exists dir then
                   Dated_jsonl.prune (Dated_jsonl.create ~base_dir:dir ()) ~days
                 else 0
               in
               let total =
                 prune_dir (Filename.concat masc "audit")
                 + prune_dir (Filename.concat masc "telemetry")
                 + prune_dir (Filename.concat (Filename.concat masc "governance") "judgments")
                 + prune_dir (Filename.concat masc "messages")
                 + prune_dir (Filename.concat masc "events")
                 + prune_dir (Filename.concat masc "activity-events")
                 + prune_dir (Filename.concat masc "voice_sessions")
                 + prune_dir (Filename.concat masc "tool_calls")
               in
               if total > 0 then
                 Log.Server.info "periodic JSONL prune: deleted %d day-files (retention=%dd)"
                   total days
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
               Log.Server.error "periodic JSONL prune failed: %s"
                 (Printexc.to_string exn))
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
  let masc_dir = Coord.masc_root_dir state.room_config in
  A2a_tools.init ~masc_dir;
  (resolved_base, masc_dir)
