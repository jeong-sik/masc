(* Server_bootstrap_maintenance — background maintenance loops
   (GC, session purge, state machine housekeeping).
   Extracted from server_bootstrap_loops.ml during godfile decomposition. *)

let fork_logged_fiber = Server_bootstrap_loops_fiber.fork_logged_fiber
let log_server_fiber_crash =
  Server_bootstrap_loops_fiber.log_server_fiber_crash

let schedule_runner_interval_sec = Server_schedule_runner_policy.interval_sec

let record_schedule_runner_tick_outcome outcome =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_schedule_runner_tick_outcomes
    ~labels:[ "outcome", outcome ]
    ()
;;

let wake_enqueue_counts_of_dispatches dispatches =
  let module Consumers = Server_schedule_consumers in
  let bump_wake_failed
        (counts : Schedule_runner_status.wake_enqueue_counts)
    =
    { counts with wake_failed = counts.wake_failed + 1 }
  in
  let bump_wake_enqueued
        (counts : Schedule_runner_status.wake_enqueue_counts)
    =
    { counts with wake_enqueued = counts.wake_enqueued + 1 }
  in
  List.fold_left
    (fun counts (dispatch : Schedule_runner.dispatch_result) ->
       match dispatch.detail with
       | None -> counts
       | Some detail ->
         (match Consumers.dispatch_receipt_of_detail detail with
          | Error _ | Ok (Consumers.Board_post_created _) -> counts
          | Ok (Consumers.Keeper_wake_enqueued { reaction_ledger_status; _ }) ->
            let counts = bump_wake_enqueued counts in
            (match reaction_ledger_status with
             | Some (Consumers.Keeper_wake_reaction_ledger_record_failed _) ->
               bump_wake_failed counts
             | None | Some Consumers.Keeper_wake_reaction_ledger_recorded ->
               counts)))
    Schedule_runner_status.empty_wake_enqueue_counts
    dispatches
;;

(* Resolve the provider config for the Memory OS per-keeper consolidation pass.
   Env var takes precedence; otherwise inherit the librarian runtime so the
   consolidation LLM uses the same JSON-capable model the librarian uses.
   An explicit but unknown runtime ID is logged and falls back to the default
   so typos in operator config are not silently masked. *)
let provider_cfg_for_memory_os_consolidation () =
  let default_cfg () =
    Runtime.get_default_runtime ()
    |> Option.map (fun rt -> rt.Runtime.provider_config)
  in
  let runtime_id =
    match Env_config.KeeperMemoryOs.consolidation_runtime_id () with
    | Some id -> Some id
    | None -> Runtime.librarian_runtime_id ()
  in
  match runtime_id with
  | None -> default_cfg ()
  | Some id ->
    (match Runtime.get_runtime_by_id id with
     | Some rt -> Some rt.Runtime.provider_config
     | None ->
       Log.Server.warn
         "memory_os_keeper_consolidation: requested runtime %s not found; \
          falling back to default"
         id;
       default_cfg ())
;;

(* P0-3: per-keeper maintenance timeout. One slow/corrupt keeper must not starve
   the rest of the fleet. Each keeper fiber gets a bounded time budget; on
   timeout we log the keeper and increment a metric so operators can see which
   stores are stalling maintenance. *)
let run_with_keeper_timeout ~clock ~timeout_sec ~keeper_id ~on_timeout f =
  match clock with
  | None -> f ()
  | Some clock ->
    (try Eio.Time.with_timeout_exn clock timeout_sec f with
     | Eio.Time.Timeout ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string MemoryOsMaintenanceKeeperTimeout)
         ~labels:[ "keeper", keeper_id ]
         ();
       on_timeout ())
;;

(* Run one consolidation pass over every keeper that currently has a fact store.
   The optional [complete] injection lets tests drive the loop with a fake model.
   The optional [timeout_sec] lets tests exercise the per-keeper timeout without
   waiting for the production default (300s). *)
let run_memory_os_consolidation_tick
      ?(complete = Keeper_memory_os_consolidation_runtime.default_complete)
      ?(timeout_sec = 300.0)
      ~sw
      ~net
      ?clock
      ~provider_cfg
      ~now
      ()
  =
  let keeper_ids = Keeper_memory_os_io.list_fact_store_keeper_ids () in
  let consolidate_one keeper_id () =
    try
      match
        Keeper_memory_os_consolidation_runtime.consolidate_keeper
          ~complete
          ~sw
          ~net
          ?clock
          ~provider_cfg
          ~now
          ~keeper_id
          ()
      with
      | Keeper_memory_os_consolidation_runtime.Consolidated { before; after } ->
        Log.Server.info
          "memory_os_keeper_consolidation: keeper=%s before=%d after=%d"
          keeper_id
          before
          after
      | Skipped_too_few n ->
        Log.Server.info
          "memory_os_keeper_consolidation: keeper=%s skipped_too_few=%d"
          keeper_id
          n
      | Transport_failed msg ->
        Log.Server.warn
          "memory_os_keeper_consolidation: keeper=%s transport_failed: %s"
          keeper_id
          msg
      | Unparseable msg ->
        Log.Server.warn
          "memory_os_keeper_consolidation: keeper=%s unparseable: %s"
          keeper_id
          msg
      | Empty_response ->
        Log.Server.warn
          "memory_os_keeper_consolidation: keeper=%s empty_response"
          keeper_id
      | Invalid_structured_response msg ->
        Log.Server.warn
          "memory_os_keeper_consolidation: keeper=%s invalid_structured_response: %s"
          keeper_id
          msg
      | Snapshot_changed { before; current } ->
        Log.Server.info
          "memory_os_keeper_consolidation: keeper=%s snapshot_changed before=%d current=%d"
          keeper_id
          before
          current
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Server.warn
        "memory_os_keeper_consolidation: keeper=%s tick crashed: %s"
        keeper_id
        (Printexc.to_string exn)
  in
  Eio.Fiber.all
    (List.map
       (fun keeper_id () ->
          run_with_keeper_timeout
            ~clock
            ~timeout_sec
            ~keeper_id
            ~on_timeout:(fun () ->
              Log.Server.warn
                "memory_os_keeper_consolidation: keeper=%s timeout after %.0fs"
                keeper_id
                timeout_sec)
            (consolidate_one keeper_id))
       keeper_ids)
;;

let start_background_maintenance ~sw ~clock ~env (state : Mcp_server.server_state) =
  (* Metrics flush fiber: drains write queue every 500ms, batches file appends.
     Replaces the old mutex + synchronous file I/O pattern. *)
  fork_logged_fiber
    ~sw
    ~on_error:(log_server_fiber_crash "metrics_flush")
    (fun () -> Metrics_store_eio.start_flush_fiber ~clock);
  Shutdown.register ~name:"metrics_flush" ~priority:30 Metrics_store_eio.flush_pending;
  (* IDE observation ingestion writer: drains the bounded ring buffer that the
     tool/pr/turn sinks enqueue into, running Yojson parse + JSONL append off
     the keeper turn fiber (main Eio domain). Shutdown drains any queued jobs
     before exit. *)
  fork_logged_fiber
    ~sw
    ~on_error:(log_server_fiber_crash "ide_ingest_writer")
    (fun () -> Ide_ingest_queue.run_writer ());
  Shutdown.register ~name:"ide_ingest_drain" ~priority:26 Ide_ingest_queue.drain_pending;
  (* RFC-0137 PR-2: host FD pressure poller. Watches sysmon's configured
     pressure state file every 1s; bridges WARN/CRIT into
     [Keeper_fd_pressure.engage_external] so the keeper scheduling gates pause
     before kern.maxfiles exhaustion can panic the kernel. Disable via
     [MASC_HOST_FD_PRESSURE_POLLER_DISABLED=1]. Sunsets when RFC-0097
     (sandbox container reuse) reaches steady state — see RFC-0137 §9. *)
  let poller_disabled = Env_config_core.host_fd_pressure_poller_disabled () in
  if not poller_disabled then
    Host_fd_pressure_poller.start
      ~sw
      ~clock
      ~base_path:(Mcp_server.workspace_config state).base_path;
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
  Tool_metrics_persist.start_flush_fiber ~sw ~clock ~base_path:(Mcp_server.workspace_config state).base_path;
  (* RFC-0234 scheduled automation runner.  Public schedule tools and the
     dashboard-only approval route only mutate the durable ledger; this loop is
     the production caller that observes due rows and emits at-most-once generic wake signals.  It
     catches per-tick failures so a corrupt schedule row or transient write
     error cannot cancel unrelated keeper/server fibers. *)
  fork_logged_fiber
    ~sw
    ~on_error:(log_server_fiber_crash "schedule_runner")
    (fun () ->
      let rec loop () =
        let started_at = Time_compat.now () in
        Schedule_runner_status.record_tick_started ~now:started_at;
        (try
           match
             Schedule_runner.tick
               ~consumer:Server_schedule_consumers.consumer
               (Mcp_server.workspace_config state)
               ~now:started_at
           with
           | Ok result ->
             let finished_at = Time_compat.now () in
             let wake_enqueue_counts =
               wake_enqueue_counts_of_dispatches result.dispatches
             in
             Schedule_runner_status.record_tick_ok
               ~wake_enqueue_counts
               ~started_at
               ~finished_at
               result;
             record_schedule_runner_tick_outcome "ok";
             if result.Schedule_runner.emitted <> []
                || result.rescheduled > 0
                || result.dispatches <> []
             then
               Log.Server.info
                 "schedule_runner: due_changed=%d emitted=%d rescheduled=%d dispatched=%d"
                 result.due_changed
                 (List.length result.emitted)
                 result.rescheduled
                 (List.length result.dispatches)
           | Error err ->
             let finished_at = Time_compat.now () in
             let error = Schedule_runner.runner_error_to_string err in
             Schedule_runner_status.record_tick_error ~started_at ~finished_at error;
             record_schedule_runner_tick_outcome "error";
             Log.Server.warn "schedule_runner: tick failed: %s" error
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           let finished_at = Time_compat.now () in
           let error = Printexc.to_string exn in
           Schedule_runner_status.record_tick_crash ~started_at ~finished_at error;
           record_schedule_runner_tick_outcome "crash";
           Log.Server.warn "schedule_runner: tick crashed: %s" error);
        Eio.Time.sleep clock schedule_runner_interval_sec;
        loop ()
      in
      loop ());
  (* RFC-0244 Tier 2 cross-keeper consolidation. The loop is off the keeper hot
     path and the consolidator itself is gated by
     [MASC_KEEPER_MEMORY_OS_CONSOLIDATE] (default false), separate from the
     per-keeper LLM consolidation gate [MASC_KEEPER_MEMORY_OS_CONSOLIDATION].
     When enabled, the typed [Ephemeral] category + [is_promotable] gate
     (#21241), the stricter [is_outcome_positive_for_shared_promotion]
     shared-tier proxy, and the durability-gate librarian prompt (#21257) keep
     non-promotable and not-yet-outcome-positive facts out of the shared tier.
     Each enabled sweep reads each keeper's Tier-1 store and rewrites the shared
     semantic store (keepers/_shared.facts.jsonl) atomically, never touching a keeper's own
     store, so it cannot race keeper writes. Per-tick failures are caught so a
     corrupt store cannot cancel sibling fibers. Each sweep logs [promoted]: a
     rising count is the regression signal to watch if producer labelling
     drifts. *)
  fork_logged_fiber
    ~sw
    ~on_error:(log_server_fiber_crash "memory_os_consolidation")
    (fun () ->
      (* Coarse cadence: consolidation is advisory and off the hot path, so a
         full fleet rescan every 5 minutes is ample. *)
      let interval = 300.0 in
      let rec loop () =
        (try
           let report =
             Keeper_memory_os_consolidator.run
               ~keeper_ids:(Keeper_memory_os_io.list_fact_store_keeper_ids ())
               ~now:(Time_compat.now ())
               ()
           in
           if report.Keeper_memory_os_consolidator.promoted > 0
           then
             Log.Server.info "memory_os_consolidation: keepers=%d promoted=%d"
               report.Keeper_memory_os_consolidator.keepers_scanned
               report.Keeper_memory_os_consolidator.promoted
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Server.warn "memory_os_consolidation: tick crashed: %s"
             (Printexc.to_string exn));
        Eio.Time.sleep clock interval;
        loop ()
      in
      loop ());
  (* RFC-0247 §2.3: memory-os forgetting sweep. Off the keeper hot path — every
     [interval]s it runs the deterministic per-keeper GC ([run_gc]: hard-expire
     facts whose [valid_until] has passed, drop fully-decayed facts by retention
     verdict, dedup by the [claim_identity] SSOT) and rewrites each keeper's
     Tier-1 store atomically. This is [run_gc]'s first production caller; without
     it the TTL/lifetime machinery (now produced per-category at librarian write
     time) is unreachable. The shared store is skipped — the consolidator
     reconstructs it wholesale each sweep, so GC-ing it would just be undone.
     Default ON; env var [MASC_KEEPER_MEMORY_OS_GC] is the kill switch. Per-keeper
     fibers run in parallel with a bounded timeout so one slow/corrupt store
     cannot starve the fleet. *)
  if Env_config.KeeperMemoryOs.gc_enabled () then
    fork_logged_fiber
      ~sw
      ~on_error:(log_server_fiber_crash "memory_os_gc")
      (fun () ->
      (* Coarser than consolidation (300s): GC rewrites stores, so a 10-minute
         cadence is ample off the hot path. *)
      let interval = 600.0 in
      let gc_one keeper_id () =
        try
          let report =
            Keeper_memory_os_gc.run_gc ~keeper_id ~now:(Time_compat.now ()) ()
          in
          if
            report.Keeper_memory_os_gc.ttl_expired > 0
            || report.dedup_removed > 0
          then
            Log.Server.info
              "memory_os_gc: keeper=%s ttl_expired=%d dedup=%d written=%d"
              keeper_id
              report.ttl_expired
              report.dedup_removed
              report.written
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Server.warn
            "memory_os_gc: keeper=%s tick crashed: %s"
            keeper_id
            (Printexc.to_string exn)
      in
      let rec loop () =
        let keeper_ids =
          List.filter
            (fun id -> not (String.equal id Keeper_memory_os_types.shared_store_id))
            (Keeper_memory_os_io.list_fact_store_keeper_ids ())
        in
        Eio.Fiber.all
          (List.map
             (fun keeper_id () ->
                run_with_keeper_timeout
                  ~clock:(Some clock)
                  ~timeout_sec:120.0
                  ~keeper_id
                  ~on_timeout:(fun () ->
                    Log.Server.warn
                      "memory_os_gc: keeper=%s timeout after 120s"
                      keeper_id)
                  (gc_one keeper_id))
             keeper_ids);
        Eio.Time.sleep clock interval;
        loop ()
      in
      loop ());
  (* RFC-0247 §2.3: per-keeper Memory OS consolidation. The librarian writes
     facts every cadence turn; without this pass a keeper's Tier-1 store only
     grows. Off the hot path: every [interval]s it asks the model to merge
     duplicate/superseded facts and rewrites the store atomically. Gated by
     [MASC_KEEPER_MEMORY_OS_CONSOLIDATION] (default false) until a live shadow
     run validates what the model would prune on the user's data. *)
  if Env_config.KeeperMemoryOs.consolidation_enabled () then
    fork_logged_fiber
      ~sw
      ~on_error:(log_server_fiber_crash "memory_os_keeper_consolidation")
      (fun () ->
        (* Coarser than Tier-2 consolidation (300s): this pass calls the LLM,
           so a 10-minute cadence bounds cost while still shrinking stores. *)
        let interval = 600.0 in
        let rec loop () =
          (match provider_cfg_for_memory_os_consolidation () with
           | None ->
             Log.Server.warn
               "memory_os_keeper_consolidation: no runtime configured; skipping tick"
           | Some provider_cfg ->
             run_memory_os_consolidation_tick
               ~sw
               ~net:env#net
               ~clock
               ~provider_cfg
               ~now:(Time_compat.now ())
               ());
          Eio.Time.sleep clock interval;
          loop ()
        in
        loop ());
  (* System_internal tool usage log: durable JSONL for pruning evidence (#5120) *)
  Tool_usage_log.init
    ~base_path:(Mcp_server.workspace_config state).base_path
    ~cluster_name:(Mcp_server.workspace_config state).backend_config.Backend_types.cluster_name
    ();
  (* Inject keeper FD/disk pressure handling at the boundary so the generic
     Tool_usage_log surface does not reference the keeper subsystem directly
     (Tool->Keeper dependency direction; this server module is the right place
     to name keeper, since the server orchestrates keepers). *)
  Tool_usage_log.install ~on_io_failure:(fun ~site exn ->
    Keeper_fd_pressure.note_exception ~site exn;
    Keeper_disk_pressure.note_exception ~site exn);
  (* Keeper tool call I/O log: full input/output for dashboard inspector *)
  Keeper_tool_call_log.init
    ~base_path:(Mcp_server.workspace_config state).base_path
    ~cluster_name:(Mcp_server.workspace_config state).backend_config.Backend_types.cluster_name
    ();
  Keeper_tool_call_log.start_flush_fiber ~sw ~clock;
  (* Transition-audit forensics writes leave the keeper hot path: recorders
     enqueue and this fiber drains (2026-06-10 fleet-freeze fix — the inline
     append serialized all keepers on one store mutex). *)
  Keeper_transition_audit.start_flush_fiber ~sw ~clock;
  Otel_dispatch_hook.install ();
  (* PR-S3: register the OTel/Otel_metric_store dispatch span wrapper. [Tool_dispatch]
     (lib/tool/, masc_tool_dispatch) no longer code-depends on [Tool_telemetry]
     / Otel / Otel_metric_store; the wrapper is injected here at the composition root.
     Without this call [guarded_dispatch] runs with the identity wrapper (no
     span / no [tool_dispatch_total] metric). *)
  Tool_dispatch.set_span_wrapper Tool_telemetry.with_span;
  Otel_metric_store.register_otel_source_once ();
  Retired_env_warnings.report_shell_ir_path_jail_if_set ~source:"startup" ();
  Otel_runtime_observables.register_once
    ~masc_root:(Workspace.masc_root_dir (Mcp_server.workspace_config state))
    ();
  Otel_spans.setup_exporter ~sw env;
  Shutdown.register ~name:"otel_exporter" ~priority:20 Otel_spans.shutdown;
  (* RFC-0217 S4-2: wire OAS OTLP exporter so OAS spans/metrics reach the
     same collector as MASC-native telemetry.  The endpoint is read from
     the same env-var that MASC's own OTLP client uses. *)
  (match Sys.getenv_opt "OTEL_EXPORTER_OTLP_ENDPOINT" with
   | Some endpoint ->
     let config = Agent_sdk.Otel_export.default_export_config ~endpoint in
     let instance = Agent_sdk.Otel_tracer.create_instance_eio () in
     let tracer = Agent_sdk.Otel_tracer.tracer_of_instance instance in
     Runtime_agent_context.set_oas_tracer tracer;
     let (_state : Agent_sdk.Otel_export.t) =
       Agent_sdk.Otel_export.start_daemon ~sw ~clock:env#clock ~net:env#net ~config instance
     in
     Log.Server.info "OAS OTLP exporter daemon started (endpoint=%s)" endpoint
   | None ->
     Log.Server.info "OTEL_EXPORTER_OTLP_ENDPOINT not set; OAS telemetry export disabled");
  (* Scheduler-lag probe: 1s sleep, gauge = overshoot. A pure-Eio fiber
     cannot observe a blocked domain from inside while it is blocked, but
     the first tick after the block lands carries the full stall duration,
     which is exactly the post-hoc signal the 2026-06 freeze RCAs lacked. *)
  fork_logged_fiber
    ~sw
    ~on_error:(log_server_fiber_crash "eio_loop_lag_probe")
    (fun () ->
      let interval_sec = 1.0 in
      let rec tick () =
        let before = Unix.gettimeofday () in
        Eio.Time.sleep clock interval_sec;
        let lag = Unix.gettimeofday () -. before -. interval_sec in
        Otel_metric_store.set_gauge
          Otel_metric_store.metric_eio_loop_lag_seconds
          (Float.max 0.0 lag);
        tick ()
      in
      tick ());
  (* Board_listener removed: filesystem-first principle.
     JSONL path emits SSE directly via Board_dispatch.emit_board_sse_event.
     PG path also uses Board_dispatch, making the pg_notify relay redundant. *)
  fork_logged_fiber
    ~sw
    ~on_error:(log_server_fiber_crash "maintenance_cleanup")
    (fun () ->
    let last_prune = ref (Unix.gettimeofday ()) in
    let base_path = (Mcp_server.workspace_config state).base_path in
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
         let evicted = Cache_eio.evict_expired (Mcp_server.workspace_config state) in
         if evicted > 0 then Log.Server.info "Cache: evicted %d expired entries" evicted;
         let sse_guards_reaped = Server_mcp_transport_http_sse.reap_stale_guards () in
         let http_guards_reaped = Server_mcp_transport_http.reap_stale_guards () in
         if sse_guards_reaped + http_guards_reaped > 0
         then
           Log.Server.info
             "reaped %d SSE guards + %d HTTP guards"
             sse_guards_reaped
             http_guards_reaped;
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
         let ar_reaped = Client_registry_eio.cleanup_stale_sessions () in
         if ar_reaped > 0
         then Log.Server.info "Reaped %d stale agent registry sessions" ar_reaped;
         (* Keeper sandbox: remove stale Docker containers when owner_pid is
             dead, container age exceeds MASC_KEEPER_SANDBOX_CLEANUP_STALE_AFTER_SEC
             (default 6h), or container is stopped. Internally throttled by
             MASC_KEEPER_SANDBOX_CLEANUP_INTERVAL_SEC (default 5min); janitor
             ticks faster but the helper short-circuits when called too soon. *)
         (match
            Keeper_sandbox_runtime.maybe_cleanup_stale_containers
              ~base_path:(Mcp_server.workspace_config state).base_path
              ~timeout_sec:
                (Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Cleanup_rm ())
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
             let masc = Workspace.masc_dir (Mcp_server.workspace_config state) in
             let prune_dir dir =
               if Sys.file_exists dir
               then Dated_jsonl.prune (Dated_jsonl.create ~base_dir:dir ()) ~days
               else 0
             in
             let prune_recall_injections () =
               match
                 Keeper_recall_injection_ledger.prune_older_than
                   ~masc_root:masc
                   ~retention_days:days
               with
               | Ok count -> count
               | Error label ->
                 Log.Server.warn
                   "periodic JSONL prune: recall_injections failed label=%s"
                   (Keeper_recall_injection_ledger.string_of_prune_error label);
                 0
             in
             let total =
               prune_dir (Filename.concat masc "audit")
               + prune_dir (Filename.concat masc "telemetry")
               + prune_dir
                   (Filename.concat (Filename.concat masc "governance") "judgments")
               + prune_dir (Filename.concat masc "messages")
               + prune_dir (Filename.concat masc "events")
               + prune_dir (Filename.concat masc "activity-events")
               + prune_recall_injections ()
               + prune_dir (Filename.concat masc "voice_sessions")
               + prune_dir (Filename.concat masc "tool_calls")
               (* transition-audit was absent from this list since its
                  introduction (RFC-0002) — 82 MB across 3 month-dirs by
                  2026-06-10, scanned by every store-fallback read. *)
               + prune_dir (Filename.concat masc "transition-audit")
             in
             if total > 0
             then
               Log.Server.info
                 "periodic JSONL prune: pruned %d day-files (retention=%dd)"
                 total
                 days;
             (* Schedule terminal-row GC on the same 24h cadence: terminal
                rows (Succeeded/Failed/Rejected/Cancelled/Expired) otherwise
                accumulate unbounded — the only pruner was the manual
                dashboard action (Server_dashboard_http_schedule_actions).
                Same operation as that button, so operator semantics are
                unchanged; the cadence bounds how long terminal history
                lingers, mirroring the dated-JSONL retention above. *)
             (match Schedule_service.prune (Mcp_server.workspace_config state) with
              | Ok (_, pruned) when pruned > 0 ->
                Log.Server.info
                  "periodic schedule prune: removed %d terminal rows"
                  pruned
              | Ok (_, _) -> ()
              | Error err ->
                Log.Server.warn
                  "periodic schedule prune failed: %s"
                  (Schedule_service.service_error_to_string err))
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
        match Repo_sync.sync_all ~base_path:(Mcp_server.workspace_config state).base_path ~now with
        | Ok synced ->
          List.iter
            (fun ((repo : Repo_manager_types.repository), outcome) ->
              match outcome with
              | Repo_sync.Already_current -> ()
              | Repo_sync.Advanced { behind } ->
                Log.Server.info
                  "repo_sync: %s advanced %d commit(s) to origin/%s"
                  repo.id behind repo.default_branch
              | Repo_sync.Skipped_dirty { staged; unstaged; conflicted } ->
                Log.Server.warn
                  "repo_sync: %s not advanced (dirty tree: staged=%d unstaged=%d conflicted=%d)"
                  repo.id staged unstaged conflicted
              | Repo_sync.Skipped_not_on_default_branch { current } ->
                Log.Server.warn
                  "repo_sync: %s not advanced (checked out %s, default %s)"
                  repo.id current repo.default_branch
              | Repo_sync.Fast_forward_refused { behind; reason } ->
                Log.Server.warn
                  "repo_sync: %s is %d commit(s) behind but fast-forward was refused: %s"
                  repo.id behind reason
              | Repo_sync.Advance_inspect_failed { reason } ->
                Log.Server.warn
                  "repo_sync: %s advance inspection failed: %s" repo.id reason)
            synced;
          if synced <> []
          then Log.Server.info "repo_sync: synced %d repositories" (List.length synced)
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
        ~sw ~clock ~config:(Mcp_server.workspace_config state) ~state
        ~interval_sec:2.0 ());
  (* Warm the runtime-probe cache before the first dashboard request so the
     shell does not open on a [warming_up] placeholder (which reads as "runtime
     down" to an operator). Non-blocking:
     [maybe_fork_dashboard_runtime_probe_refresh] forks a background fiber under
     this switch and the single-flight CAS makes a concurrent refresh a no-op. *)
  Server_dashboard_http_runtime_info.maybe_fork_dashboard_runtime_probe_refresh ();
  let resolved_base = (Mcp_server.workspace_config state).base_path in
  let masc_dir = Workspace.masc_root_dir (Mcp_server.workspace_config state) in
  resolved_base, masc_dir
;;
