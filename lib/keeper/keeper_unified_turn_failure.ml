(** Failure-path post-processing for [Keeper_unified_turn]. *)

module EC = Keeper_error_classify

let is_idle_detected_error = function
  | Agent_sdk.Error.Agent (Agent_sdk.Error.IdleDetected _) -> true
  | Agent_sdk.Error.Api _
  | Agent_sdk.Error.Provider _
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.Internal _ ->
    false
;;

let idle_detected_blocker_detail = function
  | Agent_sdk.Error.Agent (Agent_sdk.Error.IdleDetected { consecutive_idle_turns }) ->
    Printf.sprintf
      "idle loop detected: consecutive_idle_turns=%d; auto-paused after \
       repeated idle turns; operator resume clears the idle latch"
      consecutive_idle_turns
  | Agent_sdk.Error.Api _
  | Agent_sdk.Error.Provider _
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.Internal _ ->
    "idle loop detected; auto-paused after repeated idle turns; operator \
     resume clears the idle latch"
;;

let record_failure_and_maybe_escalate
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(updated_meta : Keeper_meta_contract.keeper_meta)
      ~is_auto_recoverable
      ~pacing_enforced
      ~err
      ~error_text
  =
  let base_path = config.base_path in
  let counts_toward_crash =
    (not is_auto_recoverable) || EC.is_runtime_exhausted_error err
  in
  if counts_toward_crash
  then (
    Keeper_registry.increment_turn_failures ~base_path meta.name;
    Health.record_failure
      ~agent_name:meta.name
      ~reason:(Keeper_types_profile.short_preview error_text))
  else
    Log.Keeper.info
      "%s: auto-recoverable turn failure (not counted toward crash threshold): %s"
      meta.name
      (Keeper_types_profile.short_preview error_text);
  let count = Keeper_registry.get_turn_failures ~base_path meta.name in
  let threshold =
    Runtime_params.get Governance_registry.keeper_max_turn_failures
  in
  let pause_threshold = Runtime.pause_threshold () in
  let turn_fail_streak_threshold =
    pause_threshold.Runtime_schema.turn_fail_streak_threshold
  in
  if EC.is_runtime_exhausted_error err && count > 0
  then
    Keeper_registry.set_failure_reason
      ~base_path:config.base_path
      meta.name
      (Some (Keeper_registry.Turn_consecutive_failures count));
  (* RFC-0313 W3: with [pacing.mode = enforce] a turn failure never writes
     [paused=true] — the failure was already recorded as pacing (revisit
     widening) and, for judgment classes, as a [Failure_judgment] successor in
     the heartbeat lease settlement transaction. The three auto-pause flags
     below stay reachable only in shadow mode (kill-switch, removed in W4).
     [pacing_enforced] is injected by the caller (production wires
     [Keeper_pacing_shadow.pacing_enforced ()]) so the mode is an explicit
     input at the boundary, not a hidden config read inside policy code. *)
  let runtime_auto_paused =
    (not pacing_enforced)
    && EC.is_runtime_exhausted_error err
    && count >= turn_fail_streak_threshold
    && not updated_meta.paused
  in
  let completion_contract_auto_paused =
    (not pacing_enforced)
    && EC.is_accept_no_usable_progress_error err
    && count >= turn_fail_streak_threshold
    && not updated_meta.paused
  in
  let read_only_no_progress_auto_paused =
    completion_contract_auto_paused && EC.is_read_only_no_progress_accept_rejection err
  in
  let idle_detected_auto_paused =
    (not pacing_enforced)
    && is_idle_detected_error err
    && count >= turn_fail_streak_threshold
    && not updated_meta.paused
  in
  let auto_pause_succeeded =
    if runtime_auto_paused || completion_contract_auto_paused || idle_detected_auto_paused
    then (
      let pause_meta =
        if completion_contract_auto_paused
        then
          let blocker =
            Keeper_meta_contract.blocker_info_of_class
              ~detail:
                (Keeper_types_profile.short_preview error_text)
              Keeper_meta_contract.Completion_contract_violation
          in
          { updated_meta with
            runtime = { updated_meta.runtime with last_blocker = Some blocker }
          }
        else if idle_detected_auto_paused
        then
          let blocker =
            Keeper_meta_contract.blocker_info_of_class
              ~detail:(idle_detected_blocker_detail err)
              Keeper_meta_contract.Sdk_idle_detected
          in
          { updated_meta with
            runtime = { updated_meta.runtime with last_blocker = Some blocker }
          }
        else updated_meta
      in
      let resume_policy =
        if idle_detected_auto_paused
           || (completion_contract_auto_paused && not read_only_no_progress_auto_paused)
        then Keeper_supervisor_pause_policy.Manual_resume_required
        else Keeper_supervisor_pause_policy.Auto_resume_with_backoff
      in
      match
        Keeper_turn_runtime_budget.sync_keeper_paused_state_with_resume_policy
          ~config
          ~meta:pause_meta
          ~paused:true
          ~resume_policy
      with
      | Ok _ ->
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string FailureDrivenPause)
          ~labels:[ "keeper", meta.name; "site", "turn_failure_streak" ]
          ();
        Keeper_registry.set_failure_reason
          ~base_path:config.base_path
          meta.name
          (Some (Keeper_registry.Turn_consecutive_failures count));
        if runtime_auto_paused
        then
          Log.Keeper.warn
            "%s: auto-paused after %d runtime_exhausted failures \
             (pause_threshold=%d, crash_threshold=%d); operator must resume after \
             runtime fix"
            meta.name
            count
            turn_fail_streak_threshold
            threshold
        else
          if completion_contract_auto_paused
          then
            if read_only_no_progress_auto_paused
            then
              Log.Keeper.warn
                "%s: auto-paused with backoff after %d read-only no-progress \
                 failures (pause_threshold=%d, crash_threshold=%d, \
                 task_release=policy_checked)"
                meta.name
                count
                turn_fail_streak_threshold
                threshold
            else
              Log.Keeper.warn
                "%s: auto-paused after %d completion contract no-progress failures \
                 (pause_threshold=%d, crash_threshold=%d, task_release=policy_checked); \
                 operator must inspect provider/model reasoning output before resuming"
                meta.name
                count
                turn_fail_streak_threshold
                threshold
          else
            Log.Keeper.warn
              "%s: auto-paused after %d idle-detected loop failures \
               (pause_threshold=%d, crash_threshold=%d); operator must inspect \
               repeated tool/thinking behavior before resuming"
              meta.name
              count
              turn_fail_streak_threshold
              threshold;
        true
      | Error sync_err ->
        let auto_pause_kind =
          if runtime_auto_paused
          then "runtime"
          else if completion_contract_auto_paused
          then "completion_contract"
          else "idle_detected"
        in
        Log.Keeper.error
          "%s: %s auto-pause sync failed: %s (persistent failure remains on the crash path)"
          meta.name
          auto_pause_kind
          sync_err;
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string RuntimeSyncFailures)
          ~labels:
            [ "keeper", meta.name
            ; ( "site"
              , if runtime_auto_paused
                then "auto_pause"
                else if completion_contract_auto_paused
                then "completion_contract_auto_pause"
                else "idle_detected_auto_pause" )
            ]
          ();
        false)
    else false
  in
  if count >= threshold && not auto_pause_succeeded
  then (
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string OasExecutionErrors)
      ~labels:
        [ "keeper", meta.name
        ; "phase", Keeper_oas_execution_error_phase.(to_label Persistent_escalation)
        ]
      ();
    Log.Keeper.error
      "%s: %d consecutive persistent turn failures (threshold=%d), escalating to \
       supervisor crash path"
      meta.name
      count
      threshold;
    Keeper_registry.set_failure_reason
      ~base_path:config.base_path
      meta.name
      (Some (Keeper_registry.Turn_consecutive_failures count));
    raise Keeper_registry.Keeper_fiber_crash)
;;
