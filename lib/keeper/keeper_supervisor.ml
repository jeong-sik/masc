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

type sweep_acc =
  { to_restart : (Keeper_registry.registry_entry * string) list
  ; to_unregister : Keeper_registry.registry_entry list
  ; to_cleanup_dead : Keeper_registry.registry_entry list
  }

let empty_sweep_acc =
  { to_restart = []
  ; to_unregister = []
  ; to_cleanup_dead = []
  }
;;

let pending_hitl_approval_counts config =
  let pending_entries = Keeper_approval_queue.list_pending_entries () in
  keeper_names config
  |> List.filter_map (fun name ->
       let pending_count =
         List.fold_left
           (fun count (entry : Keeper_approval_queue.pending_approval) ->
              if String.equal entry.keeper_name name
              then count + 1
              else count)
           0
           pending_entries
       in
       if pending_count = 0 then None else Some (name, pending_count))

let pending_hitl_approval_keeper_names config =
  pending_hitl_approval_counts config |> List.map fst
;;

let sweep_and_recover ~load_or_materialize_keeper_meta (ctx : _ context)
  =
  let now = Time_compat.now () in
  let dead_ttl_sec = Runtime_params.get Runtime_settings.keeper_dead_ttl_sec in
  let base_path = ctx.config.base_path in
  (* HITL requests are observable inputs, not Keeper-lane ownership. *)
  pending_hitl_approval_counts ctx.config
  |> List.iter (fun (name, pending_count) ->
       Log.Keeper.info
         "keeper:%s has %d pending HITL request(s); Keeper lane remains available"
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
    (* A crashed fiber is process reality, not authorization to pause a
       Keeper. Queue its lane for the next restart pass without an invented
       delay; restart counters remain observation only. *)
    { acc with to_restart = (entry, msg) :: acc.to_restart }
  in
  (* 2-level supervision slice: process the flat registry through stable
     8-keeper cohorts.  Each cohort re-reads its entries by name before
     processing so earlier cohort actions cannot leave later cohorts walking
     stale registry records.  The iterator yields between cohort groups; the
     yield meter still protects unusually large cohorts or non-default sizes. *)
  let process_entry (acc : sweep_acc) (entry : Keeper_registry.registry_entry) =
    match entry.phase with
    | Keeper_state_machine.Dead ->
      (match entry.dead_since_ts with
       | Some dead_since when now -. dead_since >= dead_ttl_sec ->
         { acc with to_cleanup_dead = entry :: acc.to_cleanup_dead }
       | _ -> acc)
    | Keeper_state_machine.Stopped ->
      if Keeper_registry.lane_has_exited entry
      then { acc with to_unregister = entry :: acc.to_unregister }
      else acc
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
       | None -> acc
       | Some `Stopped ->
         if Keeper_registry.lane_has_exited entry
         then { acc with to_unregister = entry :: acc.to_unregister }
         else acc
       | Some (`Crashed msg) ->
         if Keeper_registry.lane_has_exited entry
         then queue_crashed_entry acc entry msg
         else acc)
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
  let unregister_exact_and_drop (entry : Keeper_registry.registry_entry) =
    match Keeper_registry.unregister_exact entry with
    | Keeper_registry.Exact_unregistered ->
      Keeper_tool_emission_hook.drop_keeper_accumulator entry.name;
      ()
    | Keeper_registry.Exact_entry_missing -> ()
    | Keeper_registry.Exact_entry_replaced ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string SupervisorCleanupFailures)
        ~labels:[ "keeper", entry.name; "site", "stale_entry_replaced" ]
        ();
      Log.Keeper.warn
        "%s: stale supervisor entry was not unregistered because a newer lane owns the name"
        entry.name
    | Keeper_registry.Exact_unregister_lifecycle_reserved owner ->
      Log.Keeper.info
        "%s: stale registry unregister deferred to lifecycle transaction owner: %s"
        entry.name
        (Keeper_lifecycle_reservation.snapshot_to_string owner)
  in
  List.iter
    (fun (entry : Keeper_registry.registry_entry) ->
       (* K4c — reclaim only when this exact lane was removed. A stale
          sweep must not drop the accumulator of a newer same-name lane. *)
       unregister_exact_and_drop entry)
    final_acc.to_unregister;
  (* Submit exact-lane durable finalization. [Dead_cleaned] and
     [Tombstone_reaped] are emitted only by the completion receipt handler. *)
  List.iter
    (fun (entry : Keeper_registry.registry_entry) ->
       cleanup_dead_tombstone ctx entry)
    final_acc.to_cleanup_dead;
  let restart_list = final_acc.to_restart in
  (* Restart crashed keepers *)
  List.iter
    (fun ((old_entry : Keeper_registry.registry_entry), crash_msg) ->
       let attempt = old_entry.restart_count + 1 in
       match read_effective_meta ctx.config old_entry.name with
       | Ok (Some meta) ->
         let lifecycle_state =
           Keeper_lifecycle_admission.state
             ~paused:meta.paused
             ~latched_reason:meta.latched_reason
         in
         (match Keeper_lifecycle_admission.admit_autonomous lifecycle_state with
          | Keeper_lifecycle_admission.Autonomous_denied denial ->
            let reason =
              Keeper_lifecycle_admission.autonomous_denial_to_wire denial
            in
            (* The persisted meta won the admission decision, so make the
               registry observe that same authoritative snapshot before
               publishing the denial.  In particular, a stale [Running]
               registry entry paired with a persisted dead tombstone must
               become [Dead], not remain an apparently live lane that can be
               selected by phase-only consumers. *)
            Keeper_registry.update_meta
              ~base_path
              old_entry.name
              meta;
            (match denial with
             | Keeper_lifecycle_admission.Autonomous_dead_tombstone ->
               Keeper_registry.mark_dead ~base_path old_entry.name ~at:now
             | Keeper_lifecycle_admission.Autonomous_paused _ -> ());
            let denial_phase =
              match Keeper_registry.get ~base_path old_entry.name with
              | Some entry -> Some entry.phase
              | None -> None
            in
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string LifecycleDispatchRejections)
              ~labels:
                [ "keeper", old_entry.name
                ; "event", "supervisor_restart"
                ; "reason", reason
                ]
              ();
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string RestartOutcomes)
              ~labels:[ "keeper", old_entry.name; "outcome", "lifecycle_denied" ]
              ();
            publish_lifecycle
              ~event:
                (Keeper_lifecycle_events.Custom_event
                   { verb = Keeper_lifecycle_events.Admission_denied
                   ; phase = denial_phase
                   })
              old_entry.name
              reason
              ();
            Log.Keeper.info
              "%s: supervisor restart denied by lifecycle admission: %s"
              old_entry.name
              reason
          | Keeper_lifecycle_admission.Autonomous_admitted ->
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string RestartAttempts)
              ~labels:[ "keeper", old_entry.name ]
              ();
            (* Dispatch restart intent only after lifecycle admission. A
               paused or tombstoned lane never enters the restarting FSM. *)
            Keeper_registry.dispatch_event_unit
              ~base_path
              old_entry.name
              (Keeper_state_machine.Supervisor_restart_attempt { attempt });
            let old_crash_log = old_entry.crash_log in
         (match Keeper_registry.register_restarting ~base_path old_entry.name meta with
          | Error (Keeper_registry.Restart_shutdown_reserved operation_id) ->
            Log.Keeper.info
              "%s: restart skipped because shutdown operation %s owns admission"
              old_entry.name
              (Keeper_shutdown_types.Operation_id.to_string operation_id);
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string RestartOutcomes)
              ~labels:[ "keeper", old_entry.name; "outcome", "shutdown_reserved" ]
              ()
          | Error (Keeper_registry.Restart_lifecycle_reserved owner) ->
            Log.Keeper.info
              "%s: supervisor restart deferred to lifecycle transaction owner: %s"
              old_entry.name
              (Keeper_lifecycle_reservation.snapshot_to_string owner)
          | Error (Keeper_registry.Restart_event_queue_unavailable { keeper_name; detail }) ->
            Log.Keeper.error
              "%s: restart refused because durable event queue is unavailable: %s"
              keeper_name
              detail;
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string RestartOutcomes)
              ~labels:[ "keeper", keeper_name; "outcome", "event_queue_unavailable" ]
              ()
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
                  Crashed outcome re-enters the lane-local sweep with backoff. *)
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
               Log.Keeper.info "%s: restarted (attempt %d)" old_entry.name attempt);
            ))
       | _ ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string RestartOutcomes)
           ~labels:[ "keeper", old_entry.name; "outcome", "meta_unavailable" ]
         ();
         Log.Keeper.error "%s: cannot read meta for restart, removing" old_entry.name;
         (* K4c — restart-meta read failure: abandon only the exact crashed
            lane observed by this sweep. *)
         unregister_exact_and_drop old_entry)
    restart_list;
  (* Reconcile LAST — only orphaned durable keepers. A paused Keeper remains
     durable until an operator explicitly resumes, stops, or removes it. *)
  reconcile_keepalive_keepers ~load_or_materialize_keeper_meta ctx
;;
