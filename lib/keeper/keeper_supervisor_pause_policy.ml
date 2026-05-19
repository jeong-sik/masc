(** Crash-driven pause policy for the keeper supervisor.

    Extracted from [keeper_supervisor.ml] (lines 987-1180) as part of the
    godfile decomp campaign. Owns:

    - the [crash_pause_resume_policy] knob ([Manual_resume_required] vs
      [Auto_resume_with_backoff]);
    - the unified entrypoint [handle_crash_auto_pause] used by both
      stale-termination-storm and OAS-timeout-budget-loop pause paths;
    - thin per-cause wrappers [handle_stale_storm_pause] and
      [handle_oas_timeout_budget_pause];
    - the read-side classifier [failure_reason_policy_decision] that
      maps a persisted [Keeper_registry.failure_reason] back to a
      [Keeper_failure_policy.decision].

    The phase-event publisher [publish_phase_lifecycle] is injected
    explicitly so this module does not need to know about the
    [Keeper_lifecycle_events] / [Cascade_events] surface. *)

open Keeper_types
open Keeper_execution
open Keeper_supervisor_types

type crash_pause_resume_policy =
  | Manual_resume_required
  | Auto_resume_with_backoff

let handle_crash_auto_pause
      ~publish_phase_lifecycle
      (ctx : _ context)
      (entry : Keeper_registry.registry_entry)
      ~reason_tag
      ~metric_name
      ~lifecycle_detail
      ~log_message
      ~blocker_class
      ~resume_policy
  =
  (match read_meta ctx.config entry.name with
   | Ok (Some meta) ->
     let initial_sec = Env_config.KeeperSupervisor.auto_resume_initial_sec in
     let max_sec = Env_config.KeeperSupervisor.auto_resume_max_sec in
     let auto_resume_after_sec =
       match resume_policy with
       | Manual_resume_required -> None
       | Auto_resume_with_backoff ->
         next_auto_resume_after_sec ~initial_sec ~max_sec meta.auto_resume_after_sec
     in
     let blocker_text =
       let existing =
         match meta.runtime.last_blocker with
         | Some info -> String.trim info.detail
         | None -> ""
       in
       if existing <> ""
       then existing
       else (
         match blocker_class with
         | Some cls -> blocker_class_to_string cls
         | None -> reason_tag)
     in
     let blocker_info_opt =
       match blocker_class with
       | Some klass -> Some (blocker_info_of_class ~detail:blocker_text klass)
       | None ->
         (* No typed class available — preserve pre-existing typed
              info if any, otherwise drop the slot.  We refuse to
              silently fabricate a klass from [reason_tag]. *)
         meta.runtime.last_blocker
     in
     (* Task-138 §"Max no-task-progress 30min = release claimed":
          when the supervisor pauses a keeper because the same blocker
          class is looping (stale_storm or oas_timeout_budget_loop),
          the keeper is no longer making progress on its claimed task.
          Releasing [current_task_id] here lets a peer pick the task
          up while this keeper sits in [paused=true] back-off.

          Without this release the diagnostic state is "executor.json:
          current_task_id=task-147, paused=true, last_blocker.klass=
          oas_timeout_budget" — task is stuck forever because (a) this
          keeper cannot run while paused and (b) other keepers see the
          claim and skip.  The released task ID is not separately audited
          here; [last_blocker] in [runtime] already carries the pause
          reason, and Prometheus [keeper_paused_total] is incremented
          below.  Discovered 2026-05-05 fleet-stuck. *)
     (match
        write_meta_with_merge
          ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
          ctx.config
          { meta with
            paused = true
          ; auto_resume_after_sec
          ; updated_at = now_iso ()
          ; current_task_id = None
          ; runtime = { meta.runtime with last_blocker = blocker_info_opt }
          }
      with
      | Ok () -> ()
      | Error err ->
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_write_meta_failures
          ~labels:[ "keeper", entry.name; "phase", "blocker_pause" ]
          ();
        Log.Keeper.warn
          "%s: %s pause meta write failed (in-memory failure_reason still gates restart, \
           but persisted state will not survive server restart): %s"
          entry.name
          reason_tag
          err)
   | Ok None ->
     Log.Keeper.warn
       "%s: %s pause: meta missing, cannot persist paused=true"
       entry.name
       reason_tag;
     Prometheus.inc_counter
       Keeper_metrics.metric_keeper_write_meta_failures
       ~labels:[ "keeper", entry.name; "phase", "pause_meta_missing" ]
       ()
   | Error err ->
     Log.Keeper.warn "%s: %s pause read_meta failed: %s" entry.name reason_tag err;
     Prometheus.inc_counter
       Keeper_metrics.metric_keeper_write_meta_failures
       ~labels:[ "keeper", entry.name; "phase", "pause_read_meta" ]
       ());
  Prometheus.inc_counter metric_name ~labels:[ "keeper", entry.name ] ();
  publish_phase_lifecycle
    ~phase:Keeper_state_machine.Paused
    entry.name
    lifecycle_detail
    ();
  Log.Keeper.error "%s: %s" entry.name log_message
;;

let handle_stale_storm_pause
      ~publish_phase_lifecycle
      (ctx : _ context)
      (entry : Keeper_registry.registry_entry)
      ~count
  =
  handle_crash_auto_pause
    ~publish_phase_lifecycle
    ctx
    entry
    ~reason_tag:"stale_storm"
    ~metric_name:Keeper_metrics.metric_keeper_stale_storm_paused
    ~lifecycle_detail:(Printf.sprintf "stale_termination_storm count=%d" count)
    ~blocker_class:(Some Turn_timeout)
    ~resume_policy:Manual_resume_required
    ~log_message:
      (Printf.sprintf
         "STALE STORM AUTO-PAUSED (count=%d in 6h window). Auto-resume is disabled \
          until the root cause clears; operator must resume manually via masc_keeper_up \
          or API after investigating the underlying cascade/tool/runtime loop. See \
          issue #10765."
         count)
;;

let handle_oas_timeout_budget_pause
      ~publish_phase_lifecycle
      (ctx : _ context)
      (entry : Keeper_registry.registry_entry)
      ~count
  =
  handle_crash_auto_pause
    ~publish_phase_lifecycle
    ctx
    entry
    ~reason_tag:"oas_timeout_budget_loop"
    ~metric_name:Keeper_metrics.metric_keeper_oas_timeout_budget_loop_paused
    ~lifecycle_detail:(Printf.sprintf "oas_timeout_budget_loop count=%d" count)
    ~blocker_class:(Some Oas_timeout_budget)
    ~resume_policy:Auto_resume_with_backoff
    ~log_message:
      (Printf.sprintf
         "OAS TIMEOUT BUDGET LOOP AUTO-PAUSED (count=%d). Supervisor will attempt \
          self-healing auto-resume with exponential back-off (see \
          MASC_KEEPER_AUTO_RESUME_INITIAL_SEC). Operator may also tune or reroute the \
          cascade/model before resuming manually; restarting into the same slow-provider \
          budget loop is avoided by the back-off delay."
         count)
;;

let failure_reason_policy_decision
      (reason : Keeper_registry.failure_reason option)
  : Keeper_failure_policy.decision option
  =
  match reason with
  | Some (Keeper_registry.Oas_timeout_budget_loop { count }) ->
    Some
      (Keeper_failure_policy.decide
         (Keeper_failure_policy.Oas_timeout_budget
            { phase = None
            ; strikes = Some count
            ; liveness = Keeper_failure_policy.Watchdog_stale
            }))
  | Some (Keeper_registry.Stale_termination_storm { count }) ->
    Some
      (Keeper_failure_policy.decide
         (Keeper_failure_policy.Stale_termination_storm { count }))
  | Some (Keeper_registry.Stale_turn_timeout _) ->
    Some
      (Keeper_failure_policy.decide
         (Keeper_failure_policy.Stale_turn { progress_seen = false }))
  | Some (Keeper_registry.Tool_required_unsatisfied _) ->
    Some
      (Keeper_failure_policy.decide
         Keeper_failure_policy.Required_tool_contract_violation)
  | Some (Keeper_registry.Ambiguous_partial_commit _) ->
    Some (Keeper_failure_policy.decide Keeper_failure_policy.Ambiguous_partial_commit)
  | Some
      ( Keeper_registry.Heartbeat_consecutive_failures _
      | Keeper_registry.Turn_consecutive_failures _
      | Keeper_registry.Stale_fleet_batch _
      | Keeper_registry.Provider_runtime_error _
      | Keeper_registry.Fiber_unresolved
      | Keeper_registry.Exception _ )
  | None ->
    None
;;
