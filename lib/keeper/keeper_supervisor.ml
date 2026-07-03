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

(** RFC-0250: pure stale-run assessment for the no-turn-produced case.

    Returns [Some (Stale_turn_timeout (Idle_turn { stall_seconds }))] — giving
    the previously-producerless [Idle_turn] variant its first real producer —
    when the keeper is [Running], is not in a turn ([in_turn = None], the
    exact [Idle_turn] doc contract), has completed at least one turn
    ([last_turn_ts > 0], so a fresh-start keeper is not mis-stamped), and
    [now] exceeds both the last completed turn and the current supervised
    lifetime by more than [threshold]. The lifetime gate prevents a restarted
    fiber from immediately inheriting an old completed-turn timestamp and
    burning its restart budget before it has had one stale window to make
    progress. Returns [None] otherwise (alive, in-turn, fresh-start, or
    recently restarted).

    Pure: the caller stamps the reason via [Keeper_registry.set_failure_reason]
    and invokes [Keeper_execution_receipt.emit_stale_keeper_broadcast]. Keys on
    [last_turn_ts] for the reported stall while using [started_at] only as a
    current-lifetime grace anchor. It never keys on active-tool duration, so it
    does not re-introduce the deliberately-removed per-turn wall-clock
    watchdog. *)
let assess_stale_run
    ~(phase : Keeper_state_machine.phase)
    ~(in_turn : 'a option)
    ~(last_turn_ts : float)
    ~(started_at : float)
    ~(now : float)
    ~(threshold : float)
    : Keeper_registry.failure_reason option
  =
  let idle_anchor_ts = Stdlib.Float.max last_turn_ts started_at in
  if Bool.( phase = Keeper_state_machine.Running
            && Option.is_none in_turn
            && last_turn_ts > 0.0
            && now -. idle_anchor_ts > threshold )
  then
    let stall = now -. last_turn_ts in
    Some
      (Keeper_registry.Stale_turn_timeout
         (Keeper_registry_types.Idle_turn { stall_seconds = stall }))
  else None
;;

(** RFC-0012: pure in-turn progress-silence assessment.

    Returns [Some (Stale_turn_timeout (Mid_turn_no_progress { ... }))] — giving
    the previously-producerless [Mid_turn_no_progress] variant its first real
    producer — when the keeper is [Running] with a turn in progress
    ([in_turn = Some obs]) whose [last_progress_at] is older than
    [progress_timeout]. Returns [None] otherwise (not running, no turn in
    progress, or progress recorded within the window).

    Pure: like [assess_stale_run], the caller stamps the reason via
    [Keeper_registry.set_failure_reason] and invokes
    [emit_stale_keeper_broadcast]; the next sweep's [watchdog_stop_pending]
    routes the [Stale_turn_timeout _] to crash recovery. Keys on
    [last_progress_at] (tool_completed / sdk-turn boundary events recorded by
    [Keeper_registry.record_turn_progress]), never on raw turn wall-clock, so
    it is distinct from the no-turn [Idle_turn] case (the per-turn wall-clock
    timeout it would have contrasted with was deliberately removed). *)
let assess_in_turn_progress
    ~(phase : Keeper_state_machine.phase)
    ~(in_turn : Keeper_registry_types.turn_observation option)
    ~(now : float)
    ~(progress_timeout : float)
    : Keeper_registry.failure_reason option
  =
  match in_turn with
  | Some obs
    when Bool.(phase = Keeper_state_machine.Running)
         (* RFC-0197 points 2-3: a turn with a tool in flight is active tool
            execution, not no-progress. [active_tool_count] mirrors the event
            bus [pending_tool_count] (via [record_turn_tool_inflight]). A long
            silent tool call therefore does not produce [Mid_turn_no_progress];
            a hung tool is bounded by the tool substrate budget, not this
            signal. *)
         && obs.active_tool_count = 0
         && now -. obs.last_progress_at > progress_timeout ->
    Some
      (Keeper_registry.Stale_turn_timeout
         (Keeper_registry_types.Mid_turn_no_progress
            { active_seconds = now -. obs.started_at
            ; since_progress_seconds = now -. obs.last_progress_at
            ; progress_timeout_threshold = progress_timeout
            ; last_progress_kind = obs.last_progress_kind
            }))
  | Some _ | None -> None
;;

type sweep_acc =
  { to_restart : (Keeper_registry.registry_entry * string) list
  ; to_unregister : Keeper_registry.registry_entry list
  ; to_mark_dead : (Keeper_registry.registry_entry * string) list
  ; to_cleanup_dead : Keeper_registry.registry_entry list
  }

let empty_sweep_acc =
  { to_restart = []
  ; to_unregister = []
  ; to_mark_dead = []
  ; to_cleanup_dead = []
  }
;;

let release_dead_keeper_owned_tasks (ctx : _ context) (entry : Keeper_registry.registry_entry) =
  let base_path = ctx.config.base_path in
  let meta =
    match read_meta ctx.config entry.name with
    | Ok (Some meta) -> meta
    | Ok None ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ReconcileFailures)
        ~labels:[ "keeper", entry.name; "phase", "dead_task_release_meta_missing" ]
        ();
      Log.Keeper.warn
        "%s: dead-task release using registry meta because persisted meta is missing"
        entry.name;
      entry.meta
    | Error err ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ReconcileFailures)
        ~labels:[ "keeper", entry.name; "phase", "dead_task_release_meta_read" ]
        ();
      Log.Keeper.warn
        "%s: dead-task release using registry meta because persisted meta read failed: %s"
        entry.name
        err;
      entry.meta
  in
  let release_ok =
    match
      Keeper_current_task_reconcile.owned_active_tasks_for_meta ~config:ctx.config ~meta
    with
    | Error err ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ReconcileFailures)
        ~labels:[ "keeper", entry.name; "phase", "dead_task_release_discovery" ]
        ();
      Log.Keeper.error
        "%s: skipped dead-task release and current_task_id clear because owned-task \
         discovery failed: %s"
        entry.name
        err;
      false
    | Ok owned_tasks ->
      List.fold_left
        (fun all_ok (owned : Keeper_current_task_reconcile.owned_active_task) ->
           let task_id = Keeper_id.Task_id.to_string owned.task_id in
           match
             Workspace.force_release_task_r
               ctx.config
               ~agent_name:supervisor_agent_name
               ~task_id
               ()
           with
           | Ok msg ->
             Log.Keeper.warn
               "%s: released active task %s from dead owner %s after restart budget \
                exhaustion: %s"
               entry.name
               task_id
               meta.agent_name
               msg;
             all_ok
           | Error err ->
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string ReconcileFailures)
               ~labels:[ "keeper", entry.name; "phase", "dead_task_release" ]
               ();
             Log.Keeper.error
               "%s: failed to release active task %s from dead owner %s: %s"
               entry.name
               task_id
               meta.agent_name
               (Masc_domain.masc_error_to_string err);
             false)
        true
        owned_tasks
  in
  if release_ok
  then (
    match meta.current_task_id with
    | None -> ()
    | Some _ ->
      let cleared_meta =
        { meta with current_task_id = None; updated_at = now_iso () }
      in
      match
        write_meta_with_merge
          ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
          ctx.config
          cleared_meta
      with
      | Ok () -> Keeper_registry.update_meta ~base_path entry.name cleared_meta
      | Error err ->
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string WriteMetaFailures)
          ~labels:[ "keeper", entry.name; "phase", "dead_clear_current_task" ]
          ();
        Log.Keeper.warn
          "%s: failed to clear current_task_id after dead-task release: %s"
          entry.name
          err)
;;

let pending_hitl_approval_keeper_names config =
  keeper_names config
  |> List.filter (fun name ->
       Keeper_approval_queue.has_pending_for_keeper ~keeper_name:name)
;;

let sweep_and_recover ~load_or_materialize_keeper_meta (ctx : _ context) =
  let now = Time_compat.now () in
  let max_restarts =
    Runtime_params.get Governance_registry.keeper_supervisor_max_restarts
  in
  let dead_ttl_sec = Runtime_params.get Governance_registry.keeper_dead_ttl_sec in
  let base_path = ctx.config.base_path in
  (* HITL visibility: a keeper blocked on a pending approval surfaces to the
     operator only as a silent chat stall — [keeper_cycle_decision] returns
     [blocked Approval_pending] and the keeper emits no further
     chat/observation until the operator resolves the approval (or
     [approval_janitor] expires it at the 30m mark). Name the keeper and
     pending approval count on every sweep so the terminal log and downstream
     consumers can see *why* the chat is awaiting a response. *)
  pending_hitl_approval_keeper_names ctx.config
  |> List.iter (fun name ->
       let pending_count =
         Keeper_approval_queue.pending_count_for_keeper ~keeper_name:name
       in
       Log.Keeper.warn
         "keeper:%s blocked on %d pending HITL approval(s); chat awaits operator \
          decision"
         name
         pending_count);
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
  let queue_crashed_entry
        (acc : sweep_acc)
        (entry : Keeper_registry.registry_entry)
        msg
    =
    let queue_standard_restart acc =
      if entry.restart_count >= max_restarts
      then { acc with to_mark_dead = (entry, msg) :: acc.to_mark_dead }
      else (
        let delay = backoff_delay entry.restart_count in
        if now -. entry.last_restart_ts >= delay
        then { acc with to_restart = (entry, msg) :: acc.to_restart }
        else acc)
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
            increments once per storm.

            The slot is only cleared once the pause is durably committed:
            unregistering after a failed persist would drop the in-memory
            failure gate and let the reconcile loop relaunch a keeper whose
            disk meta still says [paused=false] while operators saw Paused. *)
         (match handle_stale_storm_pause ctx entry ~count with
          | Ok () -> { acc with to_unregister = entry :: acc.to_unregister }
          | Error err ->
            Log.Keeper.warn
              "%s: stale_storm pause not committed (%s); keeping registry entry \
               so the pause retries next sweep"
              entry.name
              err;
            acc)
       | Some (Keeper_registry.Provider_timeout_loop { count }) ->
         (* Watchdog-preserved provider-timeout loops include liveness evidence,
            so policy allows keeper pause without treating timeout alone as
            keeper death. Same fail-closed unregister rule as the stale-storm
            branch above. *)
         (match handle_provider_timeout_pause ctx entry ~count with
          | Ok () -> { acc with to_unregister = entry :: acc.to_unregister }
          | Error err ->
            Log.Keeper.warn
              "%s: provider_timeout_loop pause not committed (%s); keeping \
               registry entry so the pause retries next sweep"
              entry.name
              err;
            acc)
       | Some Keeper_registry.Turn_overflow_pause
       | Some Keeper_registry.Turn_livelock_pause ->
         { acc with to_unregister = entry :: acc.to_unregister }
       | Some
           ( Keeper_registry.Heartbeat_consecutive_failures _
           | Keeper_registry.Turn_consecutive_failures _
           | Keeper_registry.Stale_turn_timeout _
           | Keeper_registry.Stale_fleet_batch _
           | Keeper_registry.Provider_runtime_error _
           | Keeper_registry.Completion_contract_violation _
           | Keeper_registry.Ambiguous_partial_commit _
           | Keeper_registry.Fiber_unresolved _
           | Keeper_registry.Exception _ )
       | None ->
         queue_standard_restart acc)
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
      queue_standard_restart acc
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
    | Some (Keeper_registry.Completion_contract_violation _)
    | Some Keeper_registry.Turn_overflow_pause
    | Some Keeper_registry.Turn_livelock_pause
    | Some (Keeper_registry.Ambiguous_partial_commit _)
    | Some (Keeper_registry.Fiber_unresolved _)
    | Some (Keeper_registry.Exception _)
    | None -> false
  in
  let signal_watchdog_stop_pending
        (entry : Keeper_registry.registry_entry)
        (reason : Keeper_registry.failure_reason)
    =
    Keeper_registry.set_failure_reason ~base_path entry.name (Some reason);
    Atomic.set entry.fiber_stop true;
    Atomic.set entry.fiber_wakeup true;
    Keeper_keepalive_signal.post_wakeup_signal ~wakeup:entry.fiber_wakeup
  in
  let force_unresolved_watchdog_crash
        (acc : sweep_acc)
        (entry : Keeper_registry.registry_entry)
    =
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
      | Some (Keeper_registry.Completion_contract_violation _)
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
    match
      Keeper_registry.resolve_done
        entry
        ~source:"supervisor_force_watchdog_crash"
        (`Crashed msg)
    with
    | Keeper_registry.Done_already_resolved _ -> acc
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
      match Keeper_registry.get ~base_path entry.name with
      | Some updated -> queue_crashed_entry acc updated msg
      | None -> acc
  in
  (* 2-level supervision slice: process the flat registry through stable
     8-keeper cohorts.  Each cohort re-reads its entries by name before
     processing so earlier cohort actions cannot leave later cohorts walking
     stale registry records.  The iterator yields between cohort groups; the
     yield meter still protects unusually large cohorts or non-default sizes. *)
  let process_entry (acc : sweep_acc) (entry : Keeper_registry.registry_entry) =
    match entry.phase with
    | Keeper_state_machine.Dead | Keeper_state_machine.Zombie ->
      (match entry.dead_since_ts with
       | Some dead_since when now -. dead_since >= dead_ttl_sec ->
         { acc with to_cleanup_dead = entry :: acc.to_cleanup_dead }
       | _ -> acc)
    | Keeper_state_machine.Stopped ->
      { acc with to_unregister = entry :: acc.to_unregister }
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
         force_unresolved_watchdog_crash acc entry
       | None ->
         (* RFC-0250: stale-run window. A [Running] keeper whose
            [done_p] is unresolved and carries no [failure_reason]
            was assumed Alive, but a no-turn-produced stall is
            frozen-but-silent. Assess via the pure [assess_stale_run]
            (gives the closed [Idle_turn] variant its first real
            producer); when stale, stamp the reason and invoke the
            dead [emit_stale_keeper_broadcast] (its first call site).
            The next sweep's [watchdog_stop_pending] routes it to
            crash recovery like any other [Stale_turn_timeout].

            RFC-0012: the in-turn counterpart. When a turn IS running
            but [last_progress_at] is older than
            [Keeper_mid_turn_progress.timeout_sec_opt],
            [assess_in_turn_progress] produces [Mid_turn_no_progress] —
            giving that closed variant its first producer. Both windows are
            independent; only the mid-turn progress window is opt-in. They ride
            the same [Stale_turn_timeout] crash-recovery routing; the no-turn
            [Idle_turn] takes precedence when both would fire. *)
         let stale_run_reason =
           match Env_config_runtime.Keeper_stale_run.threshold_sec_opt () with
           | None -> None
           | Some threshold ->
             assess_stale_run
               ~phase:entry.phase
               ~in_turn:entry.current_turn_observation
               ~last_turn_ts:entry.meta.runtime.usage.last_turn_ts
               ~started_at:entry.started_at
               ~now
               ~threshold
         in
         let reason =
           match stale_run_reason with
           | Some _ -> stale_run_reason
           | None ->
             (match Env_config_runtime.Keeper_mid_turn_progress.timeout_sec_opt () with
              | None -> None
              | Some progress_timeout ->
                assess_in_turn_progress
                  ~phase:entry.phase
                  ~in_turn:entry.current_turn_observation
                  ~now
                  ~progress_timeout)
         in
         (match reason with
          | None -> acc
          | Some reason ->
            (* [stale_seconds] is a display/telemetry value, not an FSM
               transition: [Mid_turn_no_progress] reports time since last
               recorded progress; every other reason (i.e. [Idle_turn])
               preserves the original no-turn [now -. last_turn_ts]. *)
            let stale_seconds =
              match reason with
              | Keeper_registry.Stale_turn_timeout
                  (Keeper_registry_types.Mid_turn_no_progress
                     { since_progress_seconds; _ }) -> since_progress_seconds
              | _ -> now -. entry.meta.runtime.usage.last_turn_ts
            in
            signal_watchdog_stop_pending entry reason;
            Keeper_execution_receipt.emit_stale_keeper_broadcast
              ctx.config
              ~keeper_name:entry.name
              ~agent_name:entry.meta.agent_name
              ~runtime_id:(Keeper_meta_contract.runtime_id_of_meta entry.meta)
              ~trace_id:(Keeper_id.Trace_id.to_string entry.meta.runtime.trace_id)
              ~generation:entry.meta.runtime.generation
              ~failure_reason:(Some reason)
              ~stale_seconds
              ~last_turn_ts:entry.meta.runtime.usage.last_turn_ts;
            acc)
       | Some `Stopped -> { acc with to_unregister = entry :: acc.to_unregister }
       | Some (`Crashed msg) -> queue_crashed_entry acc entry msg)
  in
  let entry_cohorts = supervision_cohorts entries in
  let sweep_ym = Eio_guard.create_yield_meter () in
  let final_acc =
    List.fold_left
      (fun acc cohort ->
         let cohort_keepers = fresh_supervision_cohort_keepers ~base_path cohort in
         List.fold_left
           (fun acc entry ->
              let acc = process_entry acc entry in
              Eio_guard.yield_step sweep_ym;
              acc)
           acc
           cohort_keepers)
      empty_sweep_acc
      entry_cohorts
  in
  List.iter
    (fun (entry : Keeper_registry.registry_entry) ->
       Keeper_registry.unregister ~base_path entry.name;
       (* K4c — restart-budget exhaustion: keeper is permanently
       removed (no respawn), so reclaim its accumulator slot. *)
       Keeper_tool_emission_hook.drop_keeper_accumulator entry.name)
    final_acc.to_unregister;
  List.iter
    (fun ((entry : Keeper_registry.registry_entry), msg) ->
       (* RFC-0002: dispatch budget exhaustion before marking dead *)
       Keeper_registry.dispatch_event_unit
         ~base_path
         entry.name
         Keeper_state_machine.Restart_budget_exhausted;
       Keeper_registry.mark_dead ~base_path entry.name ~at:now;
       (* Dead keepers cannot make progress on owned tasks.  Release from the
          backlog's typed ownership state, not from a possibly stale meta
          pointer, so an exhausted keeper cannot strand an InProgress task and
          a stale current_task_id cannot release someone else's work. *)
       release_dead_keeper_owned_tasks ctx entry;
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
    final_acc.to_mark_dead;
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
    final_acc.to_cleanup_dead;
  let active_count =
    Keeper_registry.all ~base_path () |> active_supervision_keeper_count
  in
  let restart_list =
    let keepers_dir = Workspace.keepers_runtime_dir ctx.config in
    apply_self_preservation ~keepers_dir ~total_keepers:active_count final_acc.to_restart
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
            (* Note: the original ref-based accumulator appended here, but the
               append happened after the mark_dead post-processing above, so it
               had no effect in the current sweep. We keep the metric/log and
               intentionally do not accumulate, preserving the prior behavior. *)
          | Ok reg ->
            Keeper_registry.restore_supervisor_state
              ~base_path
              old_entry.name
              ~restart_count:attempt
              ~last_restart_ts:now
              ~crash_log:(keep_last_n 5 (now, crash_msg) old_crash_log);
            (match launch_supervised_fiber ~proactive_warmup_sec:0 ctx meta reg with
             | Error _ ->
               (* Launch gate aborted fail-closed (no fiber; done resolved and
                  Crashed published by the gate). Announcing Restarted/Running
                  here would report a keeper that never started; the resolved
                  Crashed outcome re-enters the sweep with backoff/budget. *)
               Otel_metric_store.inc_counter
                 Keeper_metrics.(to_string RestartOutcomes)
                 ~labels:[ "keeper", old_entry.name; "outcome", "launch_rejected" ]
                 ()
             | Ok () ->
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
                 (backoff_delay (attempt - 1)));
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
     | Ok (Some _)
     | Ok None
     | Error _ -> ());
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
           (* Record why the pruned meta was latched before the on-disk record
              is gone. [meta] was read above (pre-[Sys.remove]), so the reason
              survives in the event even though the file no longer does. *)
           let latched_reason_wire =
             match meta.latched_reason with
             | Some reason -> Keeper_latched_reason.to_wire reason
             | None -> "none"
           in
           publish_lifecycle
             ~event:
               (Keeper_lifecycle_events.Custom_event
                  { verb = Keeper_lifecycle_events.Paused_pruned; phase = None })
             name
             (Printf.sprintf
                "last_updated=%s latched_reason=%s"
                meta.updated_at
                latched_reason_wire)
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
      | Ok (Some _)
      | Ok None
      | Error _ -> ());
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
              Keeper_turn_livelock.reset_keeper_livelock
                ~base_path:ctx.config.base_path
                ~keeper:name;
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
         | Some _, Some _
         | Some _, None
         | None, Some _
         | None, None -> ())
      | Ok (Some _)
      | Ok None
      | Error _ -> ());
    Eio_guard.yield_step sweep_names_ym);
  (* Phase 4: reconcile LAST — only orphaned durable keepers *)
  reconcile_keepalive_keepers ~load_or_materialize_keeper_meta ctx
;;
