(** Keeper_supervisor — keeper keepalive fiber supervision.

    Supervises the MASC-owned background keepalive fibers that maintain
    keeper presence and heartbeat snapshots. Uses [Keeper_registry] as
    the single source of truth for keeper state.

    Launch helpers, lifecycle, backoff — extracted to
    [Keeper_supervisor_launch] (godfile decomp). *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_execution

include Keeper_supervisor_launch

let sweep_and_recover (ctx : _ context) =
  let now = Time_compat.now () in
  let max_restarts =
    Runtime_params.get Governance_registry.keeper_supervisor_max_restarts
  in
  let dead_ttl_sec = Runtime_params.get Governance_registry.keeper_dead_ttl_sec in
  let base_path = ctx.config.base_path in
  (* Phase 2: sweep order — restart/unregister FIRST, reconcile LAST.
     This prevents reconcile from re-launching keepers that sweep is about
     to process (defense-in-depth alongside is_registered check). *)
  let entries = Keeper_registry.all ~base_path () in
  (* R-A-6.c / A-7 wire-in: per-sweep snapshot invariant scan.

     Iter 14 audit (`docs/tla-audit/ksm-a6-budget-never-revives-2026-05-12.md`)
     identified that `keeper_invariant_check` was test-only — production
     never invoked it.  Iter 16 (#14758) added [check_snapshot_invariants]
     suitable for sweep-time scans.

     Policy: WARN log per violation.  Intentionally NOT halting the sweep
     or marking-dead — a violation here is a development/migration
     signal, not a runtime emergency.  Metric/alarm escalation is a
     follow-up. *)
  List.iter
    (fun (entry : Keeper_registry.registry_entry) ->
       let vs =
         Keeper_invariant_check.check_snapshot_invariants
           ~phase:entry.phase
           ~conditions:entry.conditions
       in
       List.iter
         (fun (v : Keeper_invariant_check.violation) ->
            Log.Keeper.warn
              "keeper_invariant_violation: keeper=%s phase=%s property=%s detail=%s"
              entry.name
              (Keeper_state_machine.phase_to_string entry.phase)
              v.property
              v.detail)
         vs)
    entries;
  let to_restart = ref [] in
  let to_unregister = ref [] in
  let to_mark_dead = ref [] in
  let to_cleanup_dead = ref [] in
  let queue_crashed_entry (entry : Keeper_registry.registry_entry) msg =
    let queue_standard_restart () =
      if entry.restart_count >= max_restarts
      then to_mark_dead := (entry, msg) :: !to_mark_dead
      else (
        let delay = backoff_delay entry.restart_count in
        if now -. entry.last_restart_ts >= delay
        then to_restart := (entry, msg) :: !to_restart)
    in
    match failure_reason_policy_decision entry.last_failure_reason with
    | Some
        { Keeper_failure_policy.lifecycle_effect = Keeper_failure_policy.Pause_keeper
        ; _
        } ->
      (match entry.last_failure_reason with
       | Some (Keeper_registry.Stale_termination_storm { count }) ->
         (* #10765 Phase 2: policy owns the pause-vs-restart lifecycle
            decision; this branch only applies the stale-storm pause side
            effect and clears the in-memory registry slot so the counter
            increments once per storm. *)
         handle_stale_storm_pause ctx entry ~count;
         to_unregister := entry :: !to_unregister
       | Some (Keeper_registry.Provider_timeout_loop { count }) ->
         (* Watchdog-preserved provider-timeout loops include liveness evidence,
            so policy allows keeper pause without treating timeout alone as
            keeper death. *)
         handle_provider_timeout_pause ctx entry ~count;
         to_unregister := entry :: !to_unregister
       | Some Keeper_registry.Turn_overflow_pause
       | Some Keeper_registry.Turn_livelock_pause ->
         to_unregister := entry :: !to_unregister
       | Some
           ( Keeper_registry.Heartbeat_consecutive_failures _
           | Keeper_registry.Turn_consecutive_failures _
           | Keeper_registry.Stale_turn_timeout _
           | Keeper_registry.Stale_fleet_batch _
           | Keeper_registry.Provider_runtime_error _
           | Keeper_registry.Ambiguous_partial_commit _
           | Keeper_registry.Fiber_unresolved _
           | Keeper_registry.Exception _ )
       | None ->
         queue_standard_restart ())
    | Some
        { Keeper_failure_policy.lifecycle_effect =
            ( Keeper_failure_policy.Keep_running
            | Keeper_failure_policy.Soft_fail_turn
            | Keeper_failure_policy.Pause_current_work
            | Keeper_failure_policy.Force_release_turn
            | Keeper_failure_policy.Restart_keeper )
        ; _
        }
    | None ->
      queue_standard_restart ()
  in
  let watchdog_stop_pending (entry : Keeper_registry.registry_entry) =
    Atomic.get entry.fiber_stop
    &&
    match entry.last_failure_reason with
    | Some (Keeper_registry.Stale_turn_timeout _)
    | Some (Keeper_registry.Stale_termination_storm _)
    | Some (Keeper_registry.Stale_fleet_batch _)
    | Some (Keeper_registry.Provider_timeout_loop _) -> true
    (* Other failure reasons are not stale-watchdog signals. *)
    | Some (Keeper_registry.Heartbeat_consecutive_failures _)
    | Some (Keeper_registry.Turn_consecutive_failures _)
    | Some (Keeper_registry.Provider_runtime_error _)
    | Some Keeper_registry.Turn_overflow_pause
    | Some Keeper_registry.Turn_livelock_pause
    | Some (Keeper_registry.Ambiguous_partial_commit _)
    | Some (Keeper_registry.Fiber_unresolved _)
    | Some (Keeper_registry.Exception _)
    | None -> false
  in
  let force_unresolved_watchdog_crash (entry : Keeper_registry.registry_entry) =
    let msg =
      entry.last_failure_reason
      |> Option.map Keeper_registry.failure_reason_to_string
      |> Option.value ~default:"watchdog_stop_pending"
    in
    (* 2026-05-05 cycle 9: stamp the cohort onto keeper_meta.runtime so
       the per-keeper meta surface (and PR #12877's "차단된 키퍼"
       dashboard card) shows the same diagnosis the supervisor used to
       group the keeper into a self-preservation cohort.  Companion to
       PR #12943 which added the same stamp on the [Fiber_unresolved]
       finally branch; this branch — [force_unresolved_watchdog_crash]
       — was the other silent path where the stamp was missing.
       Mapping covers all three watchdog cohorts handled by
       [watchdog_stop_pending]. *)
    let stamp_cohort =
      match entry.last_failure_reason with
      | Some (Keeper_registry.Provider_timeout_loop _) -> Some Turn_timeout
      | Some (Keeper_registry.Stale_turn_timeout _)
      | Some (Keeper_registry.Stale_fleet_batch _)
      | Some (Keeper_registry.Stale_termination_storm _) -> Some Stale_turn_timeout
      (* Non-watchdog failure reasons do not seed a watchdog blocker_class. *)
      | Some (Keeper_registry.Heartbeat_consecutive_failures _)
      | Some (Keeper_registry.Turn_consecutive_failures _)
      | Some (Keeper_registry.Provider_runtime_error _)
      | Some Keeper_registry.Turn_overflow_pause
      | Some Keeper_registry.Turn_livelock_pause
      | Some (Keeper_registry.Ambiguous_partial_commit _)
      | Some (Keeper_registry.Fiber_unresolved _)
      | Some (Keeper_registry.Exception _)
      | None -> None
    in
    (match stamp_cohort with
     | None -> ()
     | Some bc ->
       (match Keeper_registry.get ~base_path entry.name with
        | Some current ->
          let stamped_meta =
            { current.meta with
              runtime =
                { current.meta.runtime with
                  last_blocker = Some (blocker_info_of_class ~detail:msg bc)
                }
            }
          in
          (match
             write_meta_with_merge
               ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
               ctx.config
               stamped_meta
           with
           | Ok () -> ()
           | Error err ->
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string WriteMetaFailures)
               ~labels:[ "keeper", entry.name; "phase", "stale_turn_timeout_stamp" ]
               ();
             Log.Keeper.warn "%s: stale_turn_timeout meta stamp failed: %s" entry.name err)
        | None -> ()));
    Log.Keeper.warn
      "%s: supervisor forcing unresolved watchdog-stopped keeper to crashed (%s)"
      entry.name
      msg;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SupervisorCleanupFailures)
      ~labels:
        [ "keeper", entry.name
        ; ("site", Keeper_supervisor_cleanup_failure_site.(to_label Force_watchdog_crash))
        ]
      ();
    (match
       Keeper_registry.resolve_done
         entry
         ~source:"supervisor_force_watchdog_crash"
         (`Crashed msg)
     with
     | Keeper_registry.Done_already_resolved _ -> ()
     | Keeper_registry.Done_resolved _ ->
       let outcome = msg in
       ignore
         (Keeper_registry.dispatch_event_and_log
            ~base_path
            entry.name
            (Keeper_state_machine.Fiber_terminated
               { outcome; provider_id = None; http_status = None }));
       let ts = Time_compat.now () in
       Keeper_registry.record_crash ~base_path entry.name ts msg;
       Keeper_registry_error_recording.record ~base_path entry.name msg;
       (match Keeper_registry.get ~base_path entry.name with
        | Some updated -> queue_crashed_entry updated msg
        | None -> ()))
  in
  (* 2-level supervision slice: process the flat registry through stable
     8-keeper cohorts.  Each cohort re-reads its entries by name before
     processing so earlier cohort actions cannot leave later cohorts walking
     stale registry records.  The iterator yields between cohort groups; the
     yield meter still protects unusually large cohorts or non-default sizes. *)
  let entry_cohorts = supervision_cohorts entries in
  let sweep_ym = Eio_guard.create_yield_meter () in
  iter_supervision_cohorts entry_cohorts ~f:(fun cohort ->
    let cohort_keepers = fresh_supervision_cohort_keepers ~base_path cohort in
    List.iter
      (fun (entry : Keeper_registry.registry_entry) ->
         (match entry.phase with
          | Keeper_state_machine.Dead | Keeper_state_machine.Zombie ->
            (match entry.dead_since_ts with
             | Some dead_since when now -. dead_since >= dead_ttl_sec ->
               to_cleanup_dead := entry :: !to_cleanup_dead
             | _ -> ())
          | Keeper_state_machine.Stopped -> to_unregister := entry :: !to_unregister
          | Keeper_state_machine.Running
          | Keeper_state_machine.Paused
          | Keeper_state_machine.Crashed
          | Keeper_state_machine.Failing
          | Keeper_state_machine.Overflowed
          | Keeper_state_machine.Compacting
          | Keeper_state_machine.HandingOff
          | Keeper_state_machine.Draining
          | Keeper_state_machine.Restarting
          | Keeper_state_machine.Offline ->
            (match Eio.Promise.peek entry.done_p with
             | None when watchdog_stop_pending entry ->
               force_unresolved_watchdog_crash entry
             | None -> () (* Alive — skip *)
             | Some `Stopped -> to_unregister := entry :: !to_unregister
             | Some (`Crashed msg) -> queue_crashed_entry entry msg));
         Eio_guard.yield_step sweep_ym)
      cohort_keepers);
  List.iter
    (fun (entry : Keeper_registry.registry_entry) ->
       Keeper_registry.unregister ~base_path entry.name;
       (* K4c — restart-budget exhaustion: keeper is permanently
       removed (no respawn), so reclaim its accumulator slot. *)
       Keeper_tool_emission_hook.drop_keeper_accumulator entry.name)
    !to_unregister;
  List.iter
    (fun ((entry : Keeper_registry.registry_entry), msg) ->
       (* RFC-0002: dispatch budget exhaustion before marking dead *)
       Keeper_registry.dispatch_event_unit
         ~base_path
         entry.name
         Keeper_state_machine.Restart_budget_exhausted;
       Keeper_registry.mark_dead ~base_path entry.name ~at:now;
       (* Task release: Dead keepers cannot make progress on claimed tasks.
       Without this release, current_task_id stays claimed forever —
       the task is invisible to peers while this keeper is permanently
       stopped.  Mirrors handle_crash_auto_pause (line 1163). *)
       (match entry.meta.current_task_id with
        | Some _ ->
          (match read_meta ctx.config entry.name with
           | Ok (Some meta) ->
             ignore
               (write_meta_with_merge
                  ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
                  ctx.config
                  { meta with current_task_id = None })
           | _ -> ())
        | None -> ());
       let detail =
         Printf.sprintf "restart budget exhausted (%d), last: %s" max_restarts msg
       in
       publish_phase_lifecycle ~phase:Keeper_state_machine.Dead entry.name detail ();
       (* Loud alert: structured Dead event + Otel_metric_store counter so a fleet-wide
       silent crash (8 keepers, 2026-04-25) is impossible to miss in dashboard
       or metric queries. The free-form [event="dead"] on masc.keeper.lifecycle does
       not carry restart_count or the structured failure reason. *)
       let last_fr_str =
         Option.map Keeper_registry.failure_reason_to_string entry.last_failure_reason
       in
       Keeper_event_publisher.publish_keeper_dead
         ~keeper_name:entry.name
         ~reason:msg
         ~restart_count:entry.restart_count
         ~last_failure_reason:last_fr_str
         ();
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string DeadTotal)
         ~labels:
           [ "keeper", entry.name; "reason", Option.value last_fr_str ~default:"unknown" ]
         ();
       Log.Keeper.error
         "keeper DEAD (max_restarts exhausted): name=%s reason=%s restart_count=%d — \
          operator action required"
         entry.name
         msg
         entry.restart_count)
    !to_mark_dead;
  (* RFC-0036 Phase A.2: fire Tombstone_reaped after cleanup completes.
     Hook is exception-safe; supervisor never observes failure. *)
  List.iter
    (fun (entry : Keeper_registry.registry_entry) ->
       cleanup_dead_tombstone ctx entry;
       Keeper_lifecycle_hooks.run
         ~base_dir:(Workspace.masc_root_dir ctx.config)
         ~meta:entry.meta
         ~keeper_id:entry.name
         Keeper_lifecycle_hooks.Tombstone_reaped)
    !to_cleanup_dead;
  let active_count =
    Keeper_registry.all ~base_path () |> active_supervision_keeper_count
  in
  let restart_list =
    let keepers_dir = Workspace.keepers_runtime_dir ctx.config in
    apply_self_preservation ~keepers_dir ~total_keepers:active_count !to_restart
  in
  (* Restart crashed keepers *)
  List.iter
    (fun ((old_entry : Keeper_registry.registry_entry), crash_msg) ->
       let attempt = old_entry.restart_count + 1 in
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string RestartAttempts)
         ~labels:[ "keeper", old_entry.name ]
         ();
       match read_effective_meta ctx.config old_entry.name with
       | Ok (Some meta) ->
         (* RFC-0002: dispatch restart attempt event *)
         Keeper_registry.dispatch_event_unit
           ~base_path
           old_entry.name
           (Keeper_state_machine.Supervisor_restart_attempt { attempt });
         let old_crash_log = old_entry.crash_log in
         (* R-A-6.a guard: register_restarting refuses revival when the
            prior entry's restart_budget was already exhausted (TLA+ §S3
            BudgetNeverRevives).  In normal sweeps this never fires —
            the [restart_count >= max_restarts] gate at line ~1468 routes
            exhausted keepers to [to_mark_dead], not [to_restart].  A
            refusal here means some out-of-band path cleared the budget
            (one of the three vectors documented in iter 14 audit memo). *)
         (match Keeper_registry.register_restarting ~base_path old_entry.name meta with
          | Error (Keeper_registry.Budget_already_exhausted _) ->
            (* Route to mark_dead instead of merely skipping: a keeper that
               trips the BudgetNeverRevives guard should reach a stable
               terminal state, otherwise it would re-enter [to_restart]
               every sweep (an out-of-band budget reset would loop forever).
               Mark Dead makes the keeper visible to operators and exits
               the restart cycle deterministically. *)
            Log.Keeper.warn
              "%s: register_restarting refused — restart_budget_remaining=false \
               (BudgetNeverRevives guard tripped); routing to mark_dead"
              old_entry.name;
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string RestartOutcomes)
              ~labels:[ "keeper", old_entry.name; "outcome", "refused_budget_exhausted" ]
              ();
            to_mark_dead := (old_entry, crash_msg) :: !to_mark_dead
          | Ok reg ->
            Keeper_registry.restore_supervisor_state
              ~base_path
              old_entry.name
              ~restart_count:attempt
              ~last_restart_ts:now
              ~crash_log:(keep_last_n 5 (now, crash_msg) old_crash_log);
            launch_supervised_fiber ~proactive_warmup_sec:0 ctx meta reg;
            publish_lifecycle
              ~event:
                (Keeper_lifecycle_events.Custom_event
                   { verb = Keeper_lifecycle_events.Restarted
                   ; phase = Some Keeper_state_machine.Running
                   })
              old_entry.name
              (Printf.sprintf "attempt %d" attempt)
              ();
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string RestartOutcomes)
              ~labels:[ "keeper", old_entry.name; "outcome", "started" ]
              ();
            Log.Keeper.info
              "%s: restarted (attempt %d, backoff %.0fs)"
              old_entry.name
              attempt
              (backoff_delay (attempt - 1));
            (* Soft pre-warning when this is the FINAL allowed restart: next
               crash will trip the budget and mark Dead. Operator-actionable
               but not yet a fault — investigate root cause now. *)
            if attempt >= max_restarts
            then (
              Log.Keeper.warn
                "keeper near-exhaustion: name=%s restart=%d/%d — investigate"
                old_entry.name
                attempt
                max_restarts;
              Otel_metric_store.inc_counter
                Keeper_metrics.(to_string NearExhaustionTotal)
                ~labels:[ "keeper", old_entry.name ]
                ()))
       | _ ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string RestartOutcomes)
           ~labels:[ "keeper", old_entry.name; "outcome", "meta_unavailable" ]
           ();
         Log.Keeper.error "%s: cannot read meta for restart, removing" old_entry.name;
         Keeper_registry.unregister ~base_path old_entry.name;
         (* K4c — restart-meta read failure: keeper abandoned, drop. *)
         Keeper_tool_emission_hook.drop_keeper_accumulator old_entry.name)
    restart_list;
  (* Phase 2: restore paused reconcile gates whose approval queue was lost
     on restart. The queue itself is in-memory, but paused keeper meta is
     durable, so rebuild the human gate from persisted blocker evidence. *)
  let sweep_names_ym = Eio_guard.create_yield_meter () in
  Keeper_meta_store.keeper_names ctx.config
  |> List.iter (fun name ->
    (match read_meta ctx.config name with
     | Ok (Some meta)
       when paused_meta_requires_reconcile_recovery meta
            && not (Keeper_approval_queue.has_pending_for_keeper ~keeper_name:meta.name)
       -> restore_reconcile_continue_gate ctx meta
     | _ -> ());
    Eio_guard.yield_step sweep_names_ym);
  (* Phase 3: prune stale paused keeper meta files from disk. Keep
     reconcile-recovery pauses until the operator explicitly resolves them. *)
  let paused_ttl_sec = Env_config.KeeperSupervisor.paused_cleanup_ttl_sec in
  Keeper_meta_store.keeper_names ctx.config
  |> List.iter (fun name ->
    if Keeper_registry.is_running ~base_path name
    then ()
    else (
      match read_meta ctx.config name with
      | Ok (Some meta)
        when is_stale_paused_meta ~now ~paused_ttl_sec meta
             && (not (paused_meta_requires_reconcile_recovery meta))
             && not (Keeper_approval_queue.has_pending_for_keeper ~keeper_name:meta.name)
        ->
        let path = Keeper_types_profile.keeper_meta_path ctx.config name in
        (try
           Sys.remove path;
           publish_lifecycle
             ~event:
               (Keeper_lifecycle_events.Custom_event
                  { verb = Keeper_lifecycle_events.Paused_pruned; phase = None })
             name
             (Printf.sprintf "last_updated=%s" meta.updated_at)
             ();
           Log.Keeper.info "%s: stale paused meta pruned" name
         with
         | Eio.Cancel.Cancelled _ ->
           (* supervisor finally cleanup cancelled: cleanup arms must not
              re-raise cancellation, because [Fun.protect] wraps exceptions
              raised from cleanup as [Fun.Finally_raised] and can re-arm the
              2026-05-05 cycle9 incident. *)
           Log.Keeper.debug
             "%s: supervisor finally cleanup cancelled during paused meta prune"
             name
         | exn ->
           Log.Keeper.warn
             "%s: paused meta prune failed: %s"
             name
             (Printexc.to_string exn);
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string SupervisorCleanupFailures)
             ~labels:
               [ "keeper", name
               ; ("site", Keeper_supervisor_cleanup_failure_site.(to_label Paused_meta_prune))
               ]
             ())
      | _ -> ());
    Eio_guard.yield_step sweep_names_ym);
  (* Phase 3.5: self-healing circuit breaker — auto-resume keepers that were
     auto-paused and whose explicit pause timer has elapsed.  Clearing
     [paused = false] here lets Phase 4 (reconcile_keepalive_keepers) pick them
     up and restart them on the same sweep.  Reconcile-gated pauses and
     intentional operator pauses are skipped. *)
  Keeper_meta_store.keeper_names ctx.config
  |> List.iter (fun name ->
    if Keeper_registry.is_running ~base_path name
    then ()
    else (
      match read_meta ctx.config name with
      | Ok (Some meta)
        when Keeper_supervisor_types.paused_meta_auto_resume_due ~now meta
             && not (Keeper_approval_queue.has_pending_for_keeper ~keeper_name:meta.name)
        ->
        (match
           ( Keeper_supervisor_types.paused_meta_effective_auto_resume_after_sec meta
           , Workspace_resilience.Time.parse_iso8601_opt meta.updated_at )
         with
         | Some resume_after_sec, Some paused_ts
           when paused_ts > 0.0 && now -. paused_ts >= resume_after_sec ->
           ((* Resume: clear [paused] flag but retain [auto_resume_after_sec]
               so the doubled delay is ready for the next auto-pause. It will be
               reset to [None] on a successful turn completion. *)
            let resumed_meta =
              { meta with
                paused = false
              ; auto_resume_after_sec = Some resume_after_sec
              ; updated_at = now_iso ()
              ; runtime = { meta.runtime with last_blocker = None }
              }
            in
            match
              write_meta_with_merge
                ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
                ctx.config
                resumed_meta
            with
            | Ok () ->
              Keeper_turn_livelock.reset_keeper_livelock ~keeper:name;
              (match Keeper_registry.get_phase ~base_path:ctx.config.base_path name with
               | Some _ ->
                 Keeper_registry.dispatch_event_unit
                   ~base_path:ctx.config.base_path
                   name
                   Keeper_state_machine.Operator_resume;
                 Keeper_registry.wakeup ~base_path:ctx.config.base_path name
               | None -> ());
              publish_lifecycle
                ~event:
                  (Keeper_lifecycle_events.Custom_event
                     { verb = Keeper_lifecycle_events.Auto_resumed; phase = None })
                name
                (Printf.sprintf "auto_resume backoff=%.0fs" resume_after_sec)
                ();
              Otel_metric_store.inc_counter
                Keeper_metrics.(to_string AutoResumedTotal)
                ~labels:[ "keeper", name ]
                ();
              Log.Keeper.info
                "%s: auto-resumed after %.0fs backoff (next backoff=%.0fs if re-paused; \
                 resets to initial on successful turn)"
                name
                resume_after_sec
                (Float.min
                   Env_config.KeeperSupervisor.auto_resume_max_sec
                   (resume_after_sec *. 2.0))
            | Error err ->
              Otel_metric_store.inc_counter
                Keeper_metrics.(to_string WriteMetaFailures)
                ~labels:[ "keeper", name; "phase", "auto_resume" ]
                ();
              Log.Keeper.warn "%s: auto-resume meta write failed: %s" name err)
         | _ -> ())
      | _ -> ());
    Eio_guard.yield_step sweep_names_ym);
  (* Phase 4: reconcile LAST — only orphaned durable keepers *)
  reconcile_keepalive_keepers ctx
;;
