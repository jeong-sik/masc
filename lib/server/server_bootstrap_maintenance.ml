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

let log_schedule_dispatch (dispatch : Schedule_runner.dispatch_result) =
  let occurrence_id =
    Schedule_occurrence_id.to_string dispatch.occurrence_id
  in
  let status = Schedule_runner.dispatch_status_to_string dispatch.status in
  match dispatch.error with
  | None ->
    Log.Server.info
      "schedule_runner: occurrence=%s schedule_id=%s dispatch=%s"
      occurrence_id
      dispatch.schedule_id
      status
  | Some error ->
    Log.Server.warn
      "schedule_runner: occurrence=%s schedule_id=%s dispatch=%s error=%s"
      occurrence_id
      dispatch.schedule_id
      status
      error
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
          | Error _ -> counts
          | Ok
              (Consumers.Keeper_wake_enqueued
                  { occurrence_status =
                    ( Consumers.Keeper_wake_already_acked
                    | Consumers.Keeper_wake_already_failed
                    | Consumers.Keeper_wake_already_cancelled )
                ; _
                }) ->
            counts
          | Ok
              (Consumers.Keeper_wake_enqueued
                { occurrence_status = Consumers.Keeper_wake_awaiting_ack
                ; reaction_ledger_status
                ; _
                }) ->
            let counts = bump_wake_enqueued counts in
            (match reaction_ledger_status with
             | Some (Consumers.Keeper_wake_reaction_ledger_record_failed _) ->
               bump_wake_failed counts
             | None | Some Consumers.Keeper_wake_reaction_ledger_recorded ->
               counts)))
    Schedule_runner_status.empty_wake_enqueue_counts
    dispatches
;;

type transition_outbox_projection_source =
  | Startup_projection
  | Maintenance_projection

let transition_outbox_projection_source_to_string = function
  | Startup_projection -> "startup"
  | Maintenance_projection -> "maintenance"
;;

let project_keeper_transition_outboxes ~source ~base_path ~budget ~cursor =
  let page =
    Keeper_event_queue_recovery.project_discovered_bounded
      ~base_path
      ~budget
      ~cursor
  in
  let report = page.report in
  let source_label = transition_outbox_projection_source_to_string source in
  Option.iter
    (fun error ->
       Log.Server.error
         "keeper transition outbox %s discovery retained error=%s"
         source_label
         (Keeper_event_queue_recovery.discovery_error_to_string error))
    report.discovery_error;
  List.iter
    (fun (failure : Keeper_event_queue_recovery.owner_failure) ->
       Log.Server.error
         "keeper transition outbox %s retained keeper=%s error=%s"
         source_label
         failure.keeper_name
         (Keeper_event_queue_recovery.projection_error_to_string failure.error))
    report.failures;
  let should_log =
    match source with
    | Startup_projection -> true
    | Maintenance_projection ->
      report.converged > 0
      || report.claim_busy > 0
      || report.shutdown_reserved > 0
      || report.failures <> []
      || Option.is_some report.discovery_error
  in
  if should_log
  then
    Log.Server.info
      "keeper transition outbox %s discovered=%d processed=%d deferred=%d \
       converged=%d no_pending=%d claim_busy=%d shutdown_reserved=%d failures=%d"
      source_label
      report.discovered
      report.processed
      report.deferred
      report.converged
      report.no_pending
      report.claim_busy
      report.shutdown_reserved
      (List.length report.failures);
  page
;;

(* A leases term sat between these two. It could not contribute since #25969
   moved production to peek/ack and left [State.of_yojson] restoring no leases,
   so demand is decided by pending work and the transition outbox. *)
let owner_has_durable_demand state =
  not
    (Keeper_event_queue.is_empty
       (Keeper_event_queue_state.pending state))
  || Keeper_event_queue_state.transition_outbox state <> []
;;

(* Why these five are one closed type rather than ad-hoc polymorphic variants:
   [Owner_unknown] and [Owner_absent] read almost the same in English and mean
   opposite things (we could not look, versus we looked and it is not there).
   A closed type makes the compiler name every case at the log site, so a
   later state cannot slip in behind a wildcard. *)
type durable_demand_owner_error =
  | Demand_unknown of string
  | Owner_unknown of string
  | Owner_absent
  | Executor_unavailable of Executor_pool_ref.strict_submit_error
  | Demand_execution_failed of exn * Printexc.raw_backtrace

(* One ERROR per orphaned keeper per process: the condition is a standing
   operator decision, not a new event, so repeating it every recovery cycle
   buries real errors. *)
let owner_absent_reported : (string, unit) Hashtbl.t = Hashtbl.create 4

let load_durable_demand_meta ~base_path ~config ~keeper_name =
  match
    Executor_pool_ref.submit_strict (fun () ->
      match
        Keeper_event_queue_persistence.load_state_result
          ~base_path
          ~keeper_name
      with
      | Error detail -> Error (Demand_unknown detail)
      | Ok state when not (owner_has_durable_demand state) -> Ok None
      | Ok _state ->
        (match Keeper_meta_store.read_effective_meta config keeper_name with
         | Error detail -> Error (Owner_unknown detail)
         (* A store that answered and holds no such keeper is a different fact
            from a store we could not read. Folding both into [Owner_unknown]
            made an orphan queue directory -- durable work under a name no
            keeper owns -- look like a transient lookup failure, so every
            maintenance cycle logged it as a recoverable owner and moved on.
            One such directory produced 913 errors in a day. *)
         | Ok None -> Error Owner_absent
         | Ok (Some meta) -> Ok (Some meta)))
  with
  | Ok outcome -> outcome
  | Error (Executor_pool_ref.Work_failed (exn, backtrace)) ->
    Error (Demand_execution_failed (exn, backtrace))
  | Error error -> Error (Executor_unavailable error)
;;

type durable_demand_recovery_action =
  | Wake_executable_owner
  | Supervise_recoverable_owner
  | Report_unknown_owner of string
  | Retain_non_executable_owner of string

let durable_demand_recovery_action = function
  | Keeper_activation_readiness.Executable -> Wake_executable_owner
  | Keeper_activation_readiness.Recoverable -> Supervise_recoverable_owner
  | Keeper_activation_readiness.Unknown detail -> Report_unknown_owner detail
  | ( Keeper_activation_readiness.Retained_disabled _
    | Keeper_activation_readiness.Paused_dead _
    | Keeper_activation_readiness.Shutdown_fenced _ ) as retained ->
    Retain_non_executable_owner
      (Keeper_activation_readiness.owner_execution_truth_to_wire retained)
;;

let recover_projected_durable_demand_owner
      (ctx : _ Keeper_types_profile.context)
      (projection : Keeper_event_queue_recovery.owner_projection)
  =
  let base_path = ctx.config.base_path in
  let keeper_name = projection.keeper_name in
  match projection.outcome with
  | Ok Keeper_event_queue_recovery.Claim_busy ->
    Log.Server.info
      "keeper durable demand recovery retained keeper=%s reason=projection_claim_busy"
      keeper_name
  | Error (Keeper_event_queue_recovery.Owner_shutdown_reserved operation_id) ->
    Log.Server.info
      "keeper durable demand recovery retained keeper=%s reason=shutdown_reserved operation=%s"
      keeper_name
      (Keeper_shutdown_types.Operation_id.to_string operation_id)
  | Error error ->
    Log.Server.error
      "keeper durable demand recovery retained keeper=%s reason=projection_unknown detail=%s"
      keeper_name
      (Keeper_event_queue_recovery.projection_error_to_string error)
  | Ok
      ( Keeper_event_queue_recovery.No_pending_transition
      | Keeper_event_queue_recovery.Transition_converged ) ->
    (match
       load_durable_demand_meta
         ~base_path
         ~config:ctx.config
         ~keeper_name
     with
     | Error (Demand_unknown detail) ->
       Log.Server.error
         "keeper durable demand recovery retained keeper=%s reason=demand_unknown detail=%s"
         keeper_name
         detail
     | Error (Owner_unknown detail) ->
       Log.Server.error
         "keeper durable demand recovery retained keeper=%s reason=owner_unknown detail=%s"
         keeper_name
         detail
     | Error Owner_absent ->
       (* This state waits on an operator decision (register the name or
          remove the directory) that no maintenance cycle can make for it.
          The recovery loop visits every keeper every cycle, so an
          unacknowledged orphan logged at ERROR every visit -- 167/hour for
          one stale tenant queue on 2026-08-28. Say it once per process;
          the durable work stays where it is either way. *)
       if not (Hashtbl.mem owner_absent_reported keeper_name) then (
         Hashtbl.add owner_absent_reported keeper_name ();
         Log.Server.error
           "keeper durable demand orphaned keeper=%s reason=owner_absent: durable \
            work sits under %s but the Keeper store holds no metadata for that \
            name, so the work cannot execute until the name is registered or the \
            directory is removed"
           keeper_name
           (Filename.concat
              (Common.keepers_runtime_dir_of_base ~base_path)
              keeper_name))
     | Error (Executor_unavailable error) ->
       Log.Server.error
         "keeper durable demand recovery retained keeper=%s reason=executor_unavailable detail=%s"
         keeper_name
         (Executor_pool_ref.strict_submit_error_to_string error)
     | Error (Demand_execution_failed (exn, backtrace)) ->
       Log.Server.error
         "keeper durable demand recovery retained keeper=%s reason=demand_execution_failed detail=%s\n%s"
         keeper_name
         (Printexc.to_string exn)
         (Printexc.raw_backtrace_to_string backtrace)
     | Ok None -> ()
     | Ok (Some meta) ->
       let admission =
         Keeper_owner_registry.shutdown_operation_id ~base_path ~keeper_name
       in
       let runtime =
         Keeper_activation_readiness.owner_runtime_of_registry_entry
           (Keeper_registry.get ~base_path keeper_name)
       in
       let truth =
         match admission with
         | Error error ->
           Keeper_activation_readiness.Unknown
             (Keeper_owner_registry.lookup_error_to_string error)
         | Ok shutdown_operation_id ->
           Keeper_activation_readiness.classify_durable_demand_execution
             ~shutdown_operation_id
             ~runtime
             (Ok meta)
       in
       (match durable_demand_recovery_action truth with
        | Wake_executable_owner ->
          (* The durable queue survived the process that originally sent its
             wake hint. A live owner therefore still needs a new edge after
             startup or maintenance discovery; otherwise it can sleep forever
             beside runnable work. [wakeup_keeper] is only the hint -- the
             queue remains the authoritative payload. *)
          Keeper_keepalive.wakeup_keeper ~base_path keeper_name;
          Log.Server.info
            "keeper durable demand recovery woke executable owner keeper=%s"
            keeper_name
        | Supervise_recoverable_owner ->
          let owner_ctx = { ctx with agent_name = meta.name } in
          Keeper_supervisor.supervise_keepalive
            ~proactive_warmup_sec:0
            owner_ctx
            meta
        | Report_unknown_owner detail ->
          Log.Server.error
            "keeper durable demand recovery retained keeper=%s reason=unknown detail=%s"
            keeper_name
            detail
        | Retain_non_executable_owner reason ->
          Log.Server.info
            "keeper durable demand recovery retained keeper=%s reason=%s"
            keeper_name
            reason))
;;

let consume_owner_projection_batch
      ~commit_cursor
      ~keeper_name
      ~recover_owner
      projections
  =
  commit_cursor ();
  List.iter
    (fun projection ->
       let owner = keeper_name projection in
       try recover_owner projection with
       | Eio.Cancel.Cancelled _ as exn ->
         let backtrace = Printexc.get_raw_backtrace () in
         Printexc.raise_with_backtrace exn backtrace
       | exn ->
         let backtrace = Printexc.get_raw_backtrace () in
         Log.Server.error
           "keeper durable demand recovery owner failed keeper=%s error=%s\n%s"
           owner
           (Printexc.to_string exn)
           (Printexc.raw_backtrace_to_string backtrace))
    projections
;;

let recover_keeper_durable_demand_owners
      ~source
      ~budget
      ~cursor
      ~commit_cursor
      ctx
  =
  let page =
    project_keeper_transition_outboxes
      ~source
      ~base_path:ctx.Keeper_types_profile.config.base_path
      ~budget
      ~cursor
  in
  consume_owner_projection_batch
    ~commit_cursor:(fun () -> commit_cursor page.next_cursor)
    ~keeper_name:(fun
                   (projection : Keeper_event_queue_recovery.owner_projection)
                 ->
      projection.keeper_name)
    ~recover_owner:(recover_projected_durable_demand_owner ctx)
    page.report.projections
;;

module Recovery_for_testing = struct
  type nonrec durable_demand_recovery_action = durable_demand_recovery_action =
    | Wake_executable_owner
    | Supervise_recoverable_owner
    | Report_unknown_owner of string
    | Retain_non_executable_owner of string

  let durable_demand_recovery_action = durable_demand_recovery_action
  let load_durable_demand_meta = load_durable_demand_meta
  let consume_owner_projection_batch = consume_owner_projection_batch
end

let latest_keeper_msg_recovery = Atomic.make None

let latest_keeper_msg_recovery_observation () =
  Atomic.get latest_keeper_msg_recovery
;;

let recover_keeper_msg_requests_on_startup ~base_path =
  let report = Keeper_msg_async.recover_lost_disk_records ~base_path () in
  Atomic.set latest_keeper_msg_recovery (Some report);
  if
    report.lost > 0
    || report.finalized > 0
    || report.cleaned > 0
    || report.unreadable > 0
    || report.failed > 0
    || report.staging_files_deleted > 0
    || report.staging_files_preserved > 0
  then
    Log.Server.info
      "keeper_msg_async: startup recovery lost=%d finalized=%d cleaned=%d unreadable=%d failed=%d staging_inspected=%d staging_deleted=%d staging_preserved=%d"
      report.lost
      report.finalized
      report.cleaned
      report.unreadable
      report.failed
      report.staging_files_inspected
      report.staging_files_deleted
      report.staging_files_preserved;
  report
;;

let start_background_maintenance ~sw ~clock ~env (state : Mcp_server.server_state) =
  let config = Mcp_server.workspace_config state in
  (* Exclusive startup ownership: before any new server request can submit a
     worker, settle disk-only nonterminal rows left by the prior process.  Poll
     and cancel deliberately cannot infer process death, so this bootstrap
     boundary is the sole production authority for that transition. *)
  ignore
    (recover_keeper_msg_requests_on_startup ~base_path:config.base_path
      : Keeper_msg_async.recovery_report);
  let recovery_ctx : _ Keeper_types_profile.context =
    { config
    ; agent_name = "keeper-maintenance-recovery"
    ; sw
    ; clock
    ; proc_mgr = Some env#process_mgr
    ; net = state.net
    ; publication_recovery_provider =
        Mcp_server.publication_recovery_availability_provider state
    }
  in
  (* Dated-JSONL count cache: restore, keep, and hand back the per-file
     (path, boundary, count) table that makes [count_entries] incremental.

     It was process-memory only, so every restart re-counted every retained
     line of every dated store. Measured 2026-08-29: masc bootstrapped 24
     times that day, and 23 of the 28 telemetry_summary "heavy refresh"
     warnings landed within five minutes of a bootstrap -- worst 225.70s and
     5,704MB, reading tool_calls 1.1GB + agent-core-events 935MB +
     trajectories 654MB.

     The file is a cache, not a fact: every restored entry is still checked
     against its file's current size before use, so a stale, truncated, or
     absent cache costs exactly what a cold start costs today. The periodic
     save exists because a crash is a restart too, and the whole point is the
     restart path. *)
  let count_cache_path =
    Filename.concat (Workspace.masc_root_dir config) "dated-jsonl-count-cache.json"
  in
  (match Dated_jsonl.load_count_cache ~path:count_cache_path with
   | Ok 0 -> ()
   | Ok rows ->
     Log.Server.info "dated-jsonl count cache restored: rows=%d" rows
   | Error detail ->
     Log.Server.warn
       "dated-jsonl count cache load failed (counting from scratch): %s"
       detail);
  (* The trajectories store has its own incremental table with the same
     restart problem: 654MB re-read on every boot, and telemetry_summary's
     first call after one was the heavy call every time. Same contract as
     the count cache above -- rows are re-validated against file size on
     use, so a missing or stale file costs a cold read and nothing else. *)
  let trajectory_cache_path =
    Filename.concat
      (Workspace.masc_root_dir config)
      "trajectory-summary-cache.json"
  in
  (match
     Telemetry_unified.load_trajectory_summary_cache ~path:trajectory_cache_path
   with
   | Ok 0 -> ()
   | Ok rows ->
     Log.Server.info "trajectory summary cache restored: rows=%d" rows
   | Error detail ->
     Log.Server.warn
       "trajectory summary cache load failed (reading from scratch): %s"
       detail);
  let save_count_cache () =
    (match Dated_jsonl.save_count_cache ~path:count_cache_path with
     | Ok () -> ()
     | Error detail ->
       Log.Server.warn "dated-jsonl count cache save failed: %s" detail);
    match
      Telemetry_unified.save_trajectory_summary_cache ~path:trajectory_cache_path
    with
    | Ok () -> ()
    | Error detail ->
      Log.Server.warn "trajectory summary cache save failed: %s" detail
  in
  fork_logged_fiber
    ~sw
    ~on_error:(log_server_fiber_crash "dated_jsonl_count_cache")
    (fun () ->
      let interval_sec = 300.0 in
      let rec tick () =
        Eio.Time.sleep clock interval_sec;
        save_count_cache ();
        tick ()
      in
      tick ());
  Shutdown.register ~name:"dated_jsonl_count_cache" ~priority:30 save_count_cache;
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
  (* Host FD observation poller. It records sysmon WARN/CRIT signals through
     [Keeper_fd_pressure.engage_external] for health telemetry and never changes
     Keeper scheduling. Disable the observer via
     [MASC_HOST_FD_PRESSURE_POLLER_DISABLED=1]. *)
  let poller_disabled = Env_config_core.host_fd_pressure_poller_disabled () in
  if not poller_disabled then
    Host_fd_pressure_poller.start
      ~sw
      ~clock
      ~base_path:(Mcp_server.workspace_config state).base_path;
  (* Restore retained tool metrics before installing the live observer. This
     order prevents startup hydration from overwriting a call that completed
     concurrently. A failed read leaves the current snapshot unchanged and is
     visible to operators; persistence remains best-effort. *)
  let tool_metrics_base_path = (Mcp_server.workspace_config state).base_path in
  (try
     match
       Tool_metrics_persist.hydrate
         ~base_path:tool_metrics_base_path
         ~retention_days:(Env_config_core.jsonl_retention_days ())
     with
     | Ok report ->
       Log.Metrics.info
         "tool_metrics_persist: hydrated %d record(s), skipped malformed=%d invalid=%d, pruned=%d file(s)"
         report.loaded_records
         report.malformed_records
         report.invalid_records
         report.pruned_files
     | Error error ->
       Log.Metrics.warn
         "tool_metrics_persist: startup hydration failed: %s"
         (Dated_jsonl.read_error_to_string error)
   with
   | Eio.Cancel.Cancelled _ as exn -> raise exn
   | exn ->
     Log.Metrics.warn
       "tool_metrics_persist: startup hydration crashed: %s"
       (Printexc.to_string exn));
  (* The shared dispatch observer is the canonical write path for persisted
     tool metrics so keeper-internal calls are counted exactly once. *)
  Tool_dispatch.register_dispatch_observer (fun outcome result ->
    match outcome, result with
    | Dispatch_outcome.Handled, Some r ->
      Tool_metrics.record r;
      Tool_metrics_persist.enqueue r
    | _ -> ());
  Tool_metrics_persist.start_flush_fiber
    ~sw
    ~clock
    ~base_path:tool_metrics_base_path;
  (* RFC-0234 scheduled automation runner.  Public schedule tools and the
     dashboard-only approval route only mutate the durable ledger; this loop is
     the production caller that observes due rows and emits at-most-once generic wake signals.  It
     catches per-tick failures so a corrupt schedule row or transient write
     error cannot cancel unrelated keeper/server fibers. *)
  fork_logged_fiber
    ~sw
    ~on_error:(log_server_fiber_crash "schedule_runner")
    (fun () ->
      (* Recover once before this process can start a dispatch. Running is an
         in-process lease state, so a persisted row here can only belong to the
         previous process. Repeating this globally on every tick could steal an
         active dispatch from this same loop. *)
      let recovery_started_at = Time_compat.now () in
      (try
         match
           Schedule_store.recover_running_on_startup
             (Mcp_server.workspace_config state)
             ~now:recovery_started_at
         with
         | Ok (_, 0) -> ()
         | Ok (_, recovered) ->
           Log.Server.warn
             "schedule_runner: recovered %d interrupted running schedule(s)"
             recovered
         | Error err ->
           Log.Server.warn
             "schedule_runner: startup recovery failed: %s"
             (Schedule_store.store_error_to_string err)
       with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         Log.Server.warn
           "schedule_runner: startup recovery crashed: %s"
           (Printexc.to_string exn));
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
             List.iter log_schedule_dispatch result.dispatches;
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
             else
               Log.Server.debug
                 "schedule_runner: idle due_changed=0 emitted=0 rescheduled=0 dispatched=0"
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
  (* Non-public registered tool usage log: durable JSONL observability. *)
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
  Otel_runtime_observables.start_store_writer
    ~sw
    ~clock
    ~masc_root:(Workspace.masc_root_dir (Mcp_server.workspace_config state))
    ();
  Otel_spans.setup_exporter ~sw env;
  Shutdown.register ~name:"otel_exporter" ~priority:20 Otel_spans.shutdown;
  (* RFC-0217 S4-2: wire AGENT_CORE OTLP exporter so AGENT_CORE spans/metrics reach the
     same collector as MASC-native telemetry.  The endpoint is read from
     the same env-var that MASC's own OTLP client uses. *)
  (match Sys.getenv_opt "OTEL_EXPORTER_OTLP_ENDPOINT" with
   | Some endpoint ->
     let config = Agent_core.Otel_export.default_export_config ~endpoint in
     let instance = Agent_core.Otel_tracer.create_instance_eio () in
     let tracer = Agent_core.Otel_tracer.tracer_of_instance instance in
     Runtime_agent_context.set_agent_core_tracer tracer;
     let (_state : Agent_core.Otel_export.t) =
       Agent_core.Otel_export.start_daemon ~sw ~clock:env#clock ~net:env#net ~config instance
     in
     Log.Server.info "AGENT_CORE OTLP exporter daemon started (endpoint=%s)" endpoint
   | None ->
     Log.Server.info "OTEL_EXPORTER_OTLP_ENDPOINT not set; AGENT_CORE telemetry export disabled");
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
    let transition_projection_cursor =
      ref Keeper_event_queue_recovery.initial_sweep_cursor
    in
    let transition_projection_budget =
      match
        Keeper_event_queue_recovery.owner_budget
          ~max_owners:(Keeper_config.keeper_batch_limit ())
      with
      | Ok budget -> Some budget
      | Error error ->
        Log.Server.error
          "keeper transition outbox maintenance disabled: %s"
          (Keeper_event_queue_recovery.owner_budget_error_to_string error);
        None
    in
    let recover_durable_demand_owners source =
      Option.iter
        (fun budget ->
           recover_keeper_durable_demand_owners
             ~source
             ~budget
             ~cursor:!transition_projection_cursor
             ~commit_cursor:(fun next_cursor ->
               transition_projection_cursor := next_cursor)
             recovery_ctx)
        transition_projection_budget
    in
    let reconcile_broadcast_mentions () =
      match
        Workspace_broadcast.reconcile_pending_mentions
          (Mcp_server.workspace_config state)
      with
      | Error detail ->
        Log.Server.warn "broadcast mention reconciliation unavailable: %s" detail
      | Ok report ->
        List.iter
          (fun (receipt : Workspace_broadcast.mention_outbox_quarantine_receipt) ->
             Log.Server.error
               "broadcast mention quarantine source=%s quarantine=%s reason=%s sha256=%s detail=%s"
               receipt.source_name
               receipt.quarantine_name
               (Workspace_broadcast.mention_outbox_quarantine_reason_to_string
                  receipt.reason)
               receipt.raw_sha256
               receipt.detail)
          report.quarantine_receipts;
        if report.pending_rows > 0 || report.corrupt_rows > 0
        then
          Log.Server.info
            "broadcast mention reconciliation outbox=%d pending=%d accepted=%d already_accepted=%d deferred=%d rejected=%d corrupt=%d"
            report.outbox_rows
            report.pending_rows
            report.accepted
            report.already_accepted
            report.deferred
            report.rejected
            report.corrupt_rows
    in
    recover_durable_demand_owners Startup_projection;
    (* Restore MCP transport sessions from disk before first cleanup cycle.
       Grace period timestamps survive server restart, so recently-active
       clients can reconnect without "Unknown Mcp-Session-Id" errors. *)
    (try Server_mcp_transport_http_session.load_sessions_from_file ()
     with
     | Eio.Cancel.Cancelled _ as e ->
       Printexc.raise_with_backtrace e (Printexc.get_raw_backtrace ())
     | exn ->
       Log.Server.warn "session restore failed: %s" (Printexc.to_string exn));
    let rec loop () =
      Eio.Time.sleep clock Env_config_runtime.InternalTimers.janitor_interval_sec;
      recover_durable_demand_owners Maintenance_projection;
      reconcile_broadcast_mentions ();
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
         let sse_guards_reaped = Server_mcp_transport_http_conn.reap_stale_guards () in
         let http_guards_reaped = Server_mcp_transport_http.reap_stale_guards () in
         let is_active sid =
           Server_mcp_transport_http_conn.is_active_sse_session sid
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
         (* Keeper sandbox: remove Docker containers when owner_pid is dead,
             the container is stopped, or its explicit ttl_sec has elapsed.
             Containers without an explicit TTL do not expire by age. Throttled by
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
            if result.removed > 0 || result.already_absent > 0 || result.errors <> []
            then (
              Log.Server.info
                "Sandbox cleanup: scanned=%d removed=%d already_absent=%d errors=%d"
                result.scanned
                result.removed
                result.already_absent
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
               Env_config_core.jsonl_retention_days ()
             in
             let masc = Workspace.masc_dir (Mcp_server.workspace_config state) in
             let prune_dir dir =
               if Sys.file_exists dir
               then Dated_jsonl.prune (Dated_jsonl.create ~base_dir:dir ()) ~days
               else 0
             in
             let total =
               (* Store list and fold are the SSOT in
                  Server_runtime_startup_maintenance — the two inline sums
                  this replaces had already drifted (this pass lacked
                  resilience_audit; the startup pass lacked
                  tool_calls/transition-audit). *)
               Server_runtime_startup_maintenance.prune_shared_jsonl_stores
                 ~prune_dir
                 ~days
                 ~masc_root:masc
             in
             if total > 0
             then
               Log.Server.info
                 "periodic JSONL prune: pruned %d day-files (retention=%dd)"
                 total
                 days;
               (* Schedule terminal-row GC on the same 24h cadence: terminal
                  rows (Succeeded/Failed/Cancelled/Expired) otherwise
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
