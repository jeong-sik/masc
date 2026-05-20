(** Failure-path post-processing for [Keeper_unified_turn]. *)

module EC = Keeper_error_classify

let record_failure_and_maybe_escalate
      ~(config : Coord.config)
      ~(meta : Keeper_types.keeper_meta)
      ~(updated_meta : Keeper_types.keeper_meta)
      ~is_auto_recoverable
      ~err
      ~error_text
  =
  let base_path = config.base_path in
  let counts_toward_crash =
    (not is_auto_recoverable) || EC.is_cascade_exhausted_error err
  in
  if counts_toward_crash
  then Keeper_registry.increment_turn_failures ~base_path meta.name
  else
    Log.Keeper.info
      "%s: auto-recoverable turn failure (not counted toward crash threshold): %s"
      meta.name
      (Keeper_types_profile.short_preview error_text);
  let count = Keeper_registry.get_turn_failures ~base_path meta.name in
  let threshold =
    Runtime_params.get Governance_registry.keeper_max_turn_failures
  in
  Keeper_turn_cascade_budget.record_turn_failure_stress
    ~meta
    ~is_auto_recoverable
    ~consecutive:count
    ~threshold
    ~err;
  if EC.is_cascade_exhausted_error err && count > 0
  then
    Keeper_registry.set_failure_reason
      ~base_path:config.base_path
      meta.name
      (Some (Keeper_registry.Turn_consecutive_failures count));
  let cascade_auto_paused =
    EC.is_cascade_exhausted_error err
    && count >= Keeper_behavioral_regime.turn_fail_streak_threshold
    && not updated_meta.paused
  in
  let tool_contract_auto_paused =
    Keeper_unified_turn_types.should_auto_pause_required_tool_contract_violation
      ~paused:updated_meta.paused
      ~consecutive_failures:count
      err
  in
  let auto_pause_succeeded =
    if cascade_auto_paused || tool_contract_auto_paused
    then (
      let released_task_id =
        if tool_contract_auto_paused
        then Option.map Keeper_id.Task_id.to_string updated_meta.current_task_id
        else None
      in
      let pause_meta =
        if tool_contract_auto_paused
        then { updated_meta with current_task_id = None }
        else updated_meta
      in
      match
        Keeper_turn_cascade_budget.sync_keeper_paused_state_with_resume_policy
          ~config
          ~meta:pause_meta
          ~paused:true
          ~resume_policy:Keeper_supervisor_pause_policy.Auto_resume_with_backoff
      with
      | Ok _ ->
        if cascade_auto_paused
        then (
          Keeper_registry.set_failure_reason
            ~base_path:config.base_path
            meta.name
            (Some (Keeper_registry.Turn_consecutive_failures count));
          Log.Keeper.warn
            "%s: auto-paused after %d cascade_exhausted failures \
             (pause_threshold=%d, crash_threshold=%d); operator must resume after \
             cascade fix"
            meta.name
            count
            Keeper_behavioral_regime.turn_fail_streak_threshold
            threshold)
        else
          Log.Keeper.warn
            "%s: auto-paused after %d required-tool contract failures \
             (pause_threshold=%d, crash_threshold=%d, released_task=%s); operator \
             must inspect provider tool contract before resuming"
            meta.name
            count
            Keeper_behavioral_regime.turn_fail_streak_threshold
            threshold
            (Option.value ~default:"none" released_task_id);
        true
      | Error sync_err ->
        let auto_pause_kind =
          if cascade_auto_paused then "cascade" else "tool_contract"
        in
        Log.Keeper.error
          "%s: %s auto-pause sync failed: %s (persistent failure remains on the crash path)"
          meta.name
          auto_pause_kind
          sync_err;
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_cascade_sync_failures
          ~labels:
            [ "keeper", meta.name
            ; ( "site"
              , if cascade_auto_paused
                then "auto_pause"
                else "tool_contract_auto_pause" )
            ]
          ();
        false)
    else false
  in
  if count >= threshold && not auto_pause_succeeded
  then (
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_oas_execution_errors
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
