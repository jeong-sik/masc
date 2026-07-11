(** Crash-driven pause policy for the keeper supervisor.

    Extracted from [keeper_supervisor.ml] (lines 987-1180) as part of the
    godfile decomp campaign. Owns:

    - the [crash_pause_resume_policy] knob ([Manual_resume_required] vs
      [Auto_resume_with_backoff]);
    - the unified entrypoint [handle_crash_auto_pause] used by both
      stale-termination-storm and OAS-timeout-budget-loop pause paths,
      including release of backlog ownership that can no longer make
      progress while the keeper is paused;
    - thin per-cause wrappers [handle_stale_storm_pause] and
      [handle_provider_timeout_pause] (legacy registry input,
      surfaced as a provider-timeout loop);
    - the read-side classifier [failure_reason_policy_decision] that
      maps a persisted [Keeper_registry.failure_reason] back to a
      [Keeper_failure_policy.decision].

    The phase-event publisher [publish_phase_lifecycle] is injected
    explicitly so this module does not need to know about the
    [Keeper_lifecycle_events] / [Runtime_events] surface. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_execution
open Keeper_supervisor_types

type crash_pause_resume_policy =
  | Manual_resume_required
  | Auto_resume_with_backoff

let auto_resume_after_sec_for_policy meta = function
  | Manual_resume_required -> None
  | Auto_resume_with_backoff ->
    let initial_sec = Env_config.KeeperSupervisor.auto_resume_initial_sec in
    let max_sec = Env_config.KeeperSupervisor.auto_resume_max_sec in
    next_auto_resume_after_sec ~initial_sec ~max_sec meta.auto_resume_after_sec
;;

let auto_pause_handoff_context ~meta ~reason_tag =
  {
    Masc_domain.summary =
      Printf.sprintf
        "Released by keeper supervisor after %s auto-pause for %s"
        reason_tag
        meta.name;
    reason = Some "keeper_auto_pause";
    next_step = Some "Reclaim only after checking the keeper pause blocker.";
    failure_mode = Some reason_tag;
    reclaim_policy = Some Masc_domain.Allow_reclaim;
    evidence_refs = [];
    updated_at = Some (now_iso ());
    updated_by = Some supervisor_agent_name;
  }
;;

let release_owned_active_tasks_after_pause ~config ~meta ~reason_tag =
  match Keeper_current_task_reconcile.owned_active_tasks_for_meta ~config ~meta with
  | Error err ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ReconcileFailures)
      ~labels:[ "keeper", meta.name; "phase", "auto_pause_task_release_discovery" ]
      ();
    Log.Keeper.error
      "%s: skipped auto-pause task release because owned-task discovery failed: %s"
      meta.name
      err;
    false
  | Ok owned_tasks ->
    List.fold_left
      (fun all_ok (owned : Keeper_current_task_reconcile.owned_active_task) ->
         let task_id = Keeper_id.Task_id.to_string owned.task_id in
         let handoff_context = auto_pause_handoff_context ~meta ~reason_tag in
         match
           Workspace.force_release_task_r
             config
             ~agent_name:supervisor_agent_name
             ~task_id
             ~handoff_context
             ()
         with
         | Ok msg ->
           Log.Keeper.warn
             "%s: released active task %s from auto-paused owner %s (%s): %s"
             meta.name
             task_id
             meta.agent_name
             reason_tag
             msg;
           all_ok
         | Error err ->
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string ReconcileFailures)
             ~labels:[ "keeper", meta.name; "phase", "auto_pause_task_release" ]
             ();
           Log.Keeper.error
             "%s: failed to release active task %s from auto-paused owner %s (%s): %s"
             meta.name
             task_id
             meta.agent_name
             reason_tag
             (Masc_domain.masc_error_to_string err);
           false)
      true
      owned_tasks
;;

let clear_current_task_id_after_successful_pause_release ~config ~meta ~reason_tag =
  match meta.current_task_id with
  | None -> true
  | Some _ ->
    let cleared_meta =
      { meta with current_task_id = None; updated_at = now_iso () }
    in
    (match
       write_meta_with_merge
         ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
         config
         cleared_meta
     with
     | Ok () ->
       Keeper_registry.update_meta ~base_path:config.base_path meta.name cleared_meta;
       true
     | Error err ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string WriteMetaFailures)
         ~labels:[ "keeper", meta.name
                 ; "phase", Printf.sprintf "%s_pause_clear_current_task" reason_tag
                 ]
         ();
       Log.Keeper.warn
         "%s: failed to clear current_task_id after %s task release: %s"
         meta.name
         reason_tag
         err;
       false)
;;

let blocker_class_releases_owned_tasks_on_pause = function
  | Turn_timeout
  | Turn_livelock_blocked
  | No_progress_loop
  | Completion_contract_violation -> true
  | Runtime_exhausted _
  | Capacity_backpressure
  | Ambiguous_post_commit_timeout
  | Ambiguous_post_commit_failure
  | Admission_queue_wait_timeout
  | Turn_timeout_after_queue_wait
  | Fiber_unresolved
  | Stale_turn_timeout
  | Stale_fleet_batch
  | Oas_agent_execution_timeout
  | Sdk_max_turns_exceeded
  | Sdk_token_budget_exceeded
  | Sdk_cost_budget_exceeded
  | Sdk_unrecognized_stop_reason
  | Sdk_idle_detected
  | Sdk_guardrail_violation
  | Sdk_tripwire_violation
  | Sdk_exit_condition_met
  | Sdk_input_required
  | Sdk_tool_failure_recovery_failed -> false
;;

let release_owned_active_tasks_after_typed_pause ~config ~meta ~reason_tag =
  let release_required =
    meta.paused
    &&
    match meta.runtime.last_blocker with
    | Some { klass; _ } -> blocker_class_releases_owned_tasks_on_pause klass
    | None -> false
  in
  if not release_required
  then Ok meta
  else (
    let release_ok = release_owned_active_tasks_after_pause ~config ~meta ~reason_tag in
    if not release_ok
    then
      Error
        (Printf.sprintf
           "%s: %s task release failed"
           meta.name
           reason_tag)
    else if
      clear_current_task_id_after_successful_pause_release
        ~config
        ~meta
        ~reason_tag
    then Ok { meta with current_task_id = None; updated_at = now_iso () }
    else
      Error
        (Printf.sprintf
           "%s: %s current_task_id clear failed"
           meta.name
           reason_tag))
;;

let reconcile_persisted_auto_pause_task_release ~config ~meta =
  release_owned_active_tasks_after_typed_pause
    ~config
    ~meta
    ~reason_tag:"persisted_auto_pause_reconcile"
;;

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
  let persisted =
    match read_meta ctx.config entry.name with
    | Ok (Some meta) ->
      let auto_resume_after_sec =
        auto_resume_after_sec_for_policy meta resume_policy
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
          class is looping (stale_storm or provider_timeout_loop),
          the keeper is no longer making progress on its claimed task.
          Releasing [current_task_id] here lets a peer pick the task
          up while this keeper sits in [paused=true] back-off.

          Without this release the diagnostic state is "executor.json:
          current_task_id=task-147, paused=true, last_blocker.klass=
          turn_timeout" — task is stuck forever because (a) this
          keeper cannot run while paused and (b) other keepers see the
          claim and skip.  The released task ID is not separately audited
          here; [last_blocker] in [runtime] already carries the pause
          reason, and Otel_metric_store [keeper_paused_total] is incremented
          below.  Discovered 2026-05-05 fleet-stuck. *)
      let paused_meta =
        { meta with
          paused = true
        ; auto_resume_after_sec
        ; updated_at = now_iso ()
        ; runtime = { meta.runtime with last_blocker = blocker_info_opt }
        }
      in
      (match
         write_meta_with_merge
           ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
           ctx.config
           paused_meta
       with
       | Ok () ->
         let release_ok =
           release_owned_active_tasks_after_pause ~config:ctx.config ~meta ~reason_tag
         in
         if release_ok
         then
           ignore
             (clear_current_task_id_after_successful_pause_release
                ~config:ctx.config
                ~meta:paused_meta
                ~reason_tag);
         Ok ()
       | Error err ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string WriteMetaFailures)
           ~labels:[ "keeper", entry.name; "phase", "blocker_pause" ]
           ();
         Log.Keeper.warn
           "%s: %s pause meta write failed — pause not committed; Paused is not \
            published and the sweep keeps the registry entry so the pause retries \
            next sweep: %s"
           entry.name
           reason_tag
           err;
         Error err)
    | Ok None ->
      Log.Keeper.warn
        "%s: %s pause: meta missing, cannot persist paused=true — pause not committed"
        entry.name
        reason_tag;
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string WriteMetaFailures)
        ~labels:[ "keeper", entry.name; "phase", "pause_meta_missing" ]
        ();
      Error "pause meta missing"
    | Error err ->
      Log.Keeper.warn "%s: %s pause read_meta failed: %s" entry.name reason_tag err;
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string WriteMetaFailures)
        ~labels:[ "keeper", entry.name; "phase", "pause_read_meta" ]
        ();
      Error err
  in
  (* Fail closed (mirrors [handle_auto_pause_from_meta]): the Paused
     lifecycle event and the pause metric are visible operator state, so
     they must only be emitted once [paused=true] is durably committed.
     Publishing on a failed persist made the dashboard show Paused while
     the reconcile loop — after the sweep unregistered the entry —
     relaunched the keeper from disk meta with [paused=false]. *)
  match persisted with
  | Ok () ->
    Otel_metric_store.inc_counter metric_name ~labels:[ "keeper", entry.name ] ();
    publish_phase_lifecycle
      ~phase:Keeper_state_machine.Paused
      entry.name
      lifecycle_detail
      ();
    Log.Keeper.error "%s: %s" entry.name log_message;
    Ok ()
  | Error _ as err -> err
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
    ~metric_name:Keeper_metrics.(to_string StaleStormPaused)
    ~lifecycle_detail:(Printf.sprintf "stale_termination_storm count=%d" count)
    ~blocker_class:(Some Turn_timeout)
    ~resume_policy:Manual_resume_required
    ~log_message:
      (Printf.sprintf
         "STALE STORM AUTO-PAUSED (count=%d in 6h window). Auto-resume is disabled \
          until the root cause clears; operator must resume manually via masc_keeper_up \
          or API after investigating the underlying runtime/tool/runtime loop. See \
          issue #10765."
         count)
;;

let handle_provider_timeout_pause
      ~publish_phase_lifecycle
      (ctx : _ context)
      (entry : Keeper_registry.registry_entry)
      ~count
  =
  handle_crash_auto_pause
    ~publish_phase_lifecycle
    ctx
    entry
    ~reason_tag:"provider_timeout_loop"
    ~metric_name:Keeper_metrics.(to_string ProviderTimeoutLoopPaused)
    ~lifecycle_detail:(Printf.sprintf "provider_timeout_loop count=%d" count)
    ~blocker_class:(Some Turn_timeout)
    ~resume_policy:Auto_resume_with_backoff
    ~log_message:
      (Printf.sprintf
         "PROVIDER TIMEOUT LOOP AUTO-PAUSED (count=%d). Supervisor will attempt \
          self-healing auto-resume with exponential back-off (see \
          MASC_KEEPER_AUTO_RESUME_INITIAL_SEC). Operator may also tune or reroute the \
          runtime/model before resuming manually; restarting into the same slow-provider \
          timeout loop is avoided by the back-off delay."
         count)
;;

let handle_turn_failure_streak_pause
      ~publish_phase_lifecycle
      (ctx : _ context)
      (entry : Keeper_registry.registry_entry)
      ~count
  =
  (* #23439: [Keeper_failure_policy] returns a typed [Pause_keeper] verdict
     for a [Turn_failure_streak] (keeper_failure_policy.ml).  Route it to the
     same crash-auto-pause path the stale-storm / provider-timeout arms use
     instead of restarting.  [No_progress_loop] is the accurate blocker class
     (the keeper keeps running turns but none complete), and unlike a
     provider timeout the failures are not a slow-provider blip, so pausing
     surfaces the streak to operators as [Paused].  Auto-resume with
     exponential back-off (same policy as the provider-timeout turn-level
     pause): a transient cause self-heals after the back-off, while a
     persistent cause re-pauses with a doubled delay rather than restarting
     every sweep.  The blocker can still recur after an auto-resume cycle
     because resume clears the streak evidence (see #23439 RFC half — latched
     typed failure episode); this arm only stops the restart-driven
     regeneration by honoring the pause verdict. *)
  handle_crash_auto_pause
    ~publish_phase_lifecycle
    ctx
    entry
    ~reason_tag:"turn_failure_streak"
    ~metric_name:Keeper_metrics.(to_string TurnFailureStreakPaused)
    ~lifecycle_detail:(Printf.sprintf "turn_failure_streak count=%d" count)
    ~blocker_class:(Some No_progress_loop)
    ~resume_policy:Auto_resume_with_backoff
    ~log_message:
      (Printf.sprintf
         "TURN FAILURE STREAK AUTO-PAUSED (count=%d consecutive turn failures). \
          Supervisor honors the failure-policy Pause_keeper verdict instead of \
          restarting; auto-resume with exponential back-off (see \
          MASC_KEEPER_AUTO_RESUME_INITIAL_SEC) retries once the back-off delay \
          elapses. Operator may inspect the keeper's turn failures and resume \
          manually via masc_keeper_up. See issue #23439."
         count)
;;

let failure_reason_policy_decision
      (reason : Keeper_registry.failure_reason option)
  : Keeper_failure_policy.decision option
  =
  match reason with
  | Some (Keeper_registry.Provider_timeout_loop { count }) ->
    Some
      (Keeper_failure_policy.decide
         (Keeper_failure_policy.Provider_timeout
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
  | Some (Keeper_registry.Ambiguous_partial_commit _) ->
    Some (Keeper_failure_policy.decide Keeper_failure_policy.Ambiguous_partial_commit)
  | Some (Keeper_registry.Turn_consecutive_failures count) ->
    Some
      (Keeper_failure_policy.decide (Keeper_failure_policy.Turn_failure_streak { count }))
  | Some Keeper_registry.Turn_overflow_pause ->
    Some (Keeper_failure_policy.decide Keeper_failure_policy.Turn_overflow_pause)
  | Some Keeper_registry.Turn_livelock_pause ->
    Some (Keeper_failure_policy.decide Keeper_failure_policy.Turn_livelock_pause)
  | Some (Keeper_registry.Provider_runtime_error { reason = Some reason; _ }) ->
    (* Typed retryability: read the carried [runtime_exhaustion_reason]
       directly instead of reparsing the stringified [code]. The former
       [String.starts_with ~prefix:"runtime_exhausted_"] + [_ -> false]
       reparse biased transient/connectivity reasons to non-retryable. *)
    let retryable = Keeper_meta_contract.runtime_exhaustion_reason_retryable reason in
    Some
      (Keeper_failure_policy.decide
         (Keeper_failure_policy.Runtime_exhausted { retryable }))
  | Some (Keeper_registry.Provider_runtime_error { code; detail; reason = None; _ }) ->
    (match
       Keeper_provider_runtime_boundary.classify_provider_runtime_error_record
         ~code
         ~detail
     with
     | Keeper_provider_runtime_boundary.Provider_timeout timeout ->
       Some
         (Keeper_failure_policy.decide
            (Keeper_provider_runtime_boundary.provider_timeout_failure
               ~strikes:None
               ~liveness:Keeper_failure_policy.Unknown_liveness
               timeout))
     | Keeper_provider_runtime_boundary.Not_provider_runtime_failure -> None)
  | Some (Keeper_registry.Completion_contract_violation _) -> None
  | Some _ | None ->
    None
;;

(** [handle_auto_pause_from_meta ~config ~meta ~reason_tag
      ?metric_name ~lifecycle_detail ~log_message ~blocker_class
      ~resume_policy] is the turn-context SSOT for pausing a keeper.

    Unlike [handle_crash_auto_pause] (which operates on a supervisor
    registry [entry] and receives an injected publisher), this
    function works with the [config] + [meta] pair available inside
    turn logic (S3 overflow, S5 livelock, S4 runtime-exhausted).  It
    writes [paused=true] via [write_meta_with_merge] (heartbeat-field
    CAS merge, same as the overflow path), updates the registry,
    dispatches [Operator_pause] via
    [dispatch_keeper_phase_event_checked], and emits [log_message] at
    ERROR on success.

    Returns [Ok paused_meta] on success or [Error err] if the disk
    write fails.  Callers that previously fell back to in-memory
    paused state on write failure can pattern-match on [Error] and
    preserve their old behaviour. *)
let handle_auto_pause_from_meta
      ~config
      ~meta
      ~reason_tag
      ?metric_name
      ~lifecycle_detail
      ~log_message
      ~blocker_class
      ~resume_policy
      ()
  =
  let auto_resume_after_sec =
    auto_resume_after_sec_for_policy meta resume_policy
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
      (* Preserve pre-existing typed blocker info; do not fabricate
         one from [reason_tag]. *)
      meta.runtime.last_blocker
  in
  let paused_meta =
    { meta with
      paused = true
    ; auto_resume_after_sec
    ; updated_at = now_iso ()
    ; runtime = { meta.runtime with last_blocker = blocker_info_opt }
    }
  in
  match
    write_meta_with_merge
      ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
      config
      paused_meta
  with
  | Ok () ->
    (match metric_name with
     | Some name ->
       Otel_metric_store.inc_counter name ~labels:[ "keeper", meta.name ] ()
     | None -> ());
    Keeper_registry.update_meta ~base_path:config.base_path meta.name paused_meta;
    Keeper_turn_helpers.dispatch_keeper_phase_event_checked
      ~config
      ~keeper_name:meta.name
      ~side_effect:(Printf.sprintf "%s auto-pause" reason_tag)
      Keeper_state_machine.Operator_pause;
    let release_ok = release_owned_active_tasks_after_pause ~config ~meta ~reason_tag in
    let paused_meta =
      if release_ok
         && clear_current_task_id_after_successful_pause_release
              ~config
              ~meta:paused_meta
              ~reason_tag
      then { paused_meta with current_task_id = None }
      else paused_meta
    in
    Log.Keeper.error "%s: %s" meta.name log_message;
    Ok paused_meta
  | Error err ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string WriteMetaFailures)
      ~labels:[ "keeper", meta.name
              ; "phase", Printf.sprintf "%s_pause" reason_tag
              ]
      ();
    Log.Keeper.warn
      "%s: %s pause write_meta failed: %s"
      meta.name
      reason_tag
      err;
    Error err
;;
