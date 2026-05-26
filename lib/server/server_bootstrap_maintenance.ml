(* Server_bootstrap_maintenance — background maintenance loops
   (GC, session purge, state machine housekeeping).
   Extracted from server_bootstrap_loops.ml during godfile decomposition. *)

let fork_logged_fiber = Server_bootstrap_loops_fiber.fork_logged_fiber
let log_server_fiber_crash =
  Server_bootstrap_loops_fiber.log_server_fiber_crash

let start_background_maintenance ~sw ~clock ~env (state : Mcp_server.server_state) =
  (* Metrics flush fiber: drains write queue every 500ms, batches file appends.
     Replaces the old mutex + synchronous file I/O pattern. *)
  fork_logged_fiber
    ~sw
    ~on_error:(log_server_fiber_crash "metrics_flush")
    (fun () -> Metrics_store_eio.start_flush_fiber ~clock);
  Shutdown.register ~name:"metrics_flush" ~priority:30 Metrics_store_eio.flush_pending;
  (* RFC-0137 PR-2: host FD pressure poller. Watches sysmon's pressure state
     file at /tmp/masc-host-pressure.state every 1s; bridges WARN/CRIT into
     [Keeper_fd_pressure.engage_external] so the keeper scheduling gates pause
     before kern.maxfiles exhaustion can panic the kernel. Disable via
     [MASC_HOST_FD_PRESSURE_POLLER_DISABLED=1]. Sunsets when RFC-0097
     (sandbox container reuse) reaches steady state — see RFC-0137 §9. *)
  let poller_disabled =
    match Sys.getenv_opt "MASC_HOST_FD_PRESSURE_POLLER_DISABLED" with
    | Some ("1" | "true" | "TRUE") -> true
    | _ -> false
  in
  if not poller_disabled then Host_fd_pressure_poller.start ~sw ~clock;
  (* Deterministic output budget enforcement: truncate oversized tool outputs
     with structured metadata before metrics/OTEL hooks see them. *)
  Tool_output_validation.install ();
  (* Tool metrics JSONL persistence: flush buffered records to disk periodically.
     The shared dispatch observer is the canonical write path for persisted
     tool metrics so keeper-internal calls are counted exactly once. *)
  Tool_dispatch.register_dispatch_observer (fun outcome result ->
    match outcome, result with
    | Dispatch_outcome.Handled, Some r ->
      Tool_metrics.record r;
      Tool_metrics_persist.enqueue r
    | _ -> ());
  Tool_metrics_persist.start_flush_fiber ~sw ~clock ~base_path:state.room_config.base_path;
  (* Cascade trust JSONL snapshot fiber (Phase 0b observability).  Polls
     [Cascade_health_tracker.global] every minute and appends one JSON
     object per tick to base_path/cascade_trust/YYYY-MM/DD.jsonl.  Phase 1
     (in-memory trust_score) consumes these snapshots offline to calibrate
     reward / decay defaults instead of magic numbers. *)
  Cascade_trust_persist.start_snapshot_fiber
    ~sw
    ~clock
    ~base_path:state.room_config.base_path;
  (* Bare-alias audit fiber (PR #15112 surface refresh): re-run the
     classifier every minute so the [masc_auth_bare_alias] gauges
     reflect mid-run regressions, not only the boot snapshot. The
     keeper roster is re-queried per tick via the closure so a
     runtime add/remove is picked up without restarting the fiber. *)
  Auth.start_bare_alias_audit_fiber
    ~sw
    ~clock
    ~base_path:state.room_config.base_path
    ~canonical_names_fn:(fun () ->
      Keeper_runtime.bootable_keeper_names state.room_config
      |> List.map Keeper_identity.keeper_agent_name);
  (* #9876: Hebbian consolidation fiber. Prior to this, the graph was
     write-only — strengthen/weaken populated synapses but decay +
     pruning never ran (zero production callers of [consolidate]).
     last_consolidation=0.0 on live graphs confirmed the gap in
     production. *)
  (* System_internal tool usage log: durable JSONL for pruning evidence (#5120) *)
  Tool_usage_log.init
    ~base_path:state.room_config.base_path
    ~cluster_name:state.room_config.backend_config.Backend_types.cluster_name
    ();
  Tool_usage_log.install ();
  (* Keeper tool call I/O log: full input/output for dashboard inspector *)
  Keeper_tool_call_log.init
    ~base_path:state.room_config.base_path
    ~cluster_name:state.room_config.backend_config.Backend_types.cluster_name
    ();
  Keeper_tool_call_log.start_flush_fiber ~sw ~clock;
  Otel_dispatch_hook.install ();
  Otel_spans.setup_exporter ~sw env;
  Shutdown.register ~name:"otel_exporter" ~priority:20 Otel_spans.shutdown;
  (* Board_listener removed: filesystem-first principle.
     JSONL path emits SSE directly via Board_dispatch.emit_board_sse_event.
     PG path also uses Board_dispatch, making the pg_notify relay redundant. *)
  fork_logged_fiber
    ~sw
    ~on_error:(log_server_fiber_crash "maintenance_cleanup")
    (fun () ->
    let last_prune = ref (Unix.gettimeofday ()) in
    let rec loop () =
      Eio.Time.sleep clock Env_config_runtime.InternalTimers.janitor_interval_sec;
      (try
         let stale_sids = Sse.cleanup_stale () in
         List.iter Server_routes_http_common.stop_sse_session stale_sids;
         if stale_sids <> []
         then
           Log.Server.info
             "Reaped %d stale connections (active: %d)"
             (List.length stale_sids)
             (Sse.client_count ());
         let evicted_events = Sse.cleanup_expired_events () in
         if evicted_events > 0
         then
           (* SSE replay-buffer eviction is periodic housekeeping; failed
               sends and stale connection reaping remain visible elsewhere. *)
           Log.Server.routine "Evicted %d expired SSE buffer events" evicted_events;
         let evicted = Cache_eio.evict_expired state.room_config in
         if evicted > 0 then Log.Server.info "Cache: evicted %d expired entries" evicted;
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
         if sse_guards_reaped + http_guards_reaped + sessions_reaped > 0
         then
           Log.Server.info
             "reaped %d SSE guards + %d HTTP guards + %d stale sessions"
             sse_guards_reaped
             http_guards_reaped
             sessions_reaped;
         let ext_reaped = Sse.reap_dead_external_subscribers () in
         Transport_metrics.set_grpc_subscribers
           (Sse.external_subscriber_count_with_prefix "grpc-subscribe-");
         if ext_reaped > 0
         then Log.Server.info "reaped %d dead external subscribers" ext_reaped;
         if Server_webrtc_transport.is_enabled ()
         then (
           let webrtc_expired = Server_webrtc_transport.cleanup_expired_offers () in
           let webrtc_stale_peers = Server_webrtc_transport.cleanup_stale_peers () in
           if webrtc_expired > 0 || webrtc_stale_peers > 0
           then
             Log.Server.info "WebRTC: cleaned %d expired offers, %d stale peers"
               webrtc_expired
               webrtc_stale_peers);
         (* Rate-limit buckets: evict keys unused for
             [MASC_RATE_LIMIT_BUCKET_TTL_SEC] (default 5 minutes) *)
         let rl = Eio.Lazy.force Rate_limit.global in
         let rl_reaped =
           Rate_limit.cleanup
             rl
             ~older_than_seconds:
               Env_config_runtime.InternalTimers.rate_limit_bucket_ttl_sec
         in
         if rl_reaped > 0
         then Log.Server.info "Reaped %d stale rate-limit buckets" rl_reaped;
         (* Agent registry: remove resolved-name cache for dead sessions *)
         let ar_reaped = Agent_registry_eio.cleanup_stale_sessions () in
         if ar_reaped > 0
         then Log.Server.info "Reaped %d stale agent registry sessions" ar_reaped;
         (* Keeper sandbox: remove stale Docker containers when owner_pid is
             dead, container age exceeds MASC_KEEPER_SANDBOX_CLEANUP_STALE_AFTER_SEC
             (default 6h), or container is stopped. Internally throttled by
             MASC_KEEPER_SANDBOX_CLEANUP_INTERVAL_SEC (default 5min); janitor
             ticks faster but the helper short-circuits when called too soon. *)
         (match
            Keeper_sandbox_runtime.maybe_cleanup_stale_containers
              ~base_path:state.room_config.base_path
              ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Startup ())
              ()
          with
          | None -> ()
          | Some result ->
            if result.removed > 0 || result.errors <> []
            then (
              Log.Server.info
                "Sandbox cleanup: scanned=%d removed=%d errors=%d"
                result.scanned
                result.removed
                (List.length result.errors);
              List.iter
                (fun err -> Log.Server.warn "Sandbox cleanup error: %s" err)
                result.errors));
         (* Periodic JSONL prune: every 24h, clean dated JSONL files *)
         let now = Unix.gettimeofday () in
         if now -. !last_prune >= Masc_time_constants.day
         then (
           last_prune := now;
           try
             let days =
               Safe_ops.get_env_int_logged "MASC_JSONL_RETENTION_DAYS" ~default:30
             in
             let masc = Coord.masc_dir state.room_config in
             let prune_dir dir =
               if Sys.file_exists dir
               then Dated_jsonl.prune (Dated_jsonl.create ~base_dir:dir ()) ~days
               else 0
             in
             let total =
               prune_dir (Filename.concat masc "audit")
               + prune_dir (Filename.concat masc "telemetry")
               + prune_dir
                   (Filename.concat (Filename.concat masc "governance") "judgments")
               + prune_dir (Filename.concat masc "messages")
               + prune_dir (Filename.concat masc "events")
               + prune_dir (Filename.concat masc "activity-events")
               + prune_dir (Filename.concat masc "voice_sessions")
               + prune_dir (Filename.concat masc "tool_calls")
             in
             if total > 0
             then
               Log.Server.info
                 "periodic JSONL prune: deleted %d day-files (retention=%dd)"
                 total
                 days
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
             Log.Server.error "periodic JSONL prune failed: %s" (Printexc.to_string exn))
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Server.error "cleanup loop iteration failed: %s" (Printexc.to_string exn));
      loop ()
    in
    loop ());
  (* Periodic repository sync: fetch repositories with auto_sync enabled. *)
  fork_logged_fiber
    ~sw
    ~on_error:(log_server_fiber_crash "repo_sync")
    (fun () ->
    let repo_sync_interval_sec =
      Env_config_runtime.InternalTimers.repo_sync_interval_sec
    in
    let sync_once () =
      try
        let now = Int64.of_float (Eio.Time.now clock) in
        match Repo_sync.sync_all ~base_path:state.room_config.base_path ~now with
        | Ok repos ->
          if repos <> []
          then Log.Server.info "repo_sync: synced %d repositories" (List.length repos)
        | Error msg -> Log.Server.warn "repo_sync: sync_all failed: %s" msg
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> Log.Server.error "repo_sync: iteration failed: %s" (Printexc.to_string exn)
    in
    let rec sync_loop () =
      (try Eio.Time.sleep clock repo_sync_interval_sec with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn -> Log.Server.error "repo_sync: sleep failed: %s" (Printexc.to_string exn));
      sync_once ();
      sync_loop ()
    in
    sync_once ();
    sync_loop ());
  (* RFC-0138 Phase 3 Step 1: lock-free dashboard snapshot refresher.
     Publishes shell/tools/telemetry_summary every [interval_sec] so
     HTTP read handlers can serve via wait-free [Atomic.get] instead of
     racing the synchronous compute path through [Dashboard_cache].

     The interval (2.0s) matches RFC-0138 §6 Q2: frontend polls /shell
     every 3s, so a 2s refresh keeps staleness bounded at 5s (2s + 3s)
     while leaving the compute path fully out of the request fiber. *)
  fork_logged_fiber
    ~sw
    ~on_error:(log_server_fiber_crash "dashboard_snapshot refresh")
    (fun () ->
      (* RFC-0138 Phase 3 Step 3: pass [~state] so refresh_loop can
         populate [namespace_truth] from the cached-refs path.
         That moves the 6 MASC_NAMESPACE_TRUTH_*_TIMEOUT_S knobs out
         of the request fiber for the canonical project-snapshot
         response (Step 4 retires the env knobs themselves). *)
      Dashboard_snapshot.refresh_loop
        ~sw ~clock ~config:state.room_config ~state
        ~interval_sec:2.0 ());
  let resolved_base = state.room_config.base_path in
  let masc_dir = Coord.masc_root_dir state.room_config in
  resolved_base, masc_dir
;;
