(** Keeper_unified_turn_success_lifecycle — lifecycle application,
    loop detection, cost estimation, and runtime lane label
    extracted from [Keeper_unified_turn_success] (583 LoC).
    @since Keeper 500-line decomposition *)

module KCB = Keeper_turn_cascade_budget
module KEC = Keeper_exec_context
module KUM = Keeper_unified_metrics

(* RFC-0132 PR-2: success-path keeper-facing metric label = external boundary; redact via SSOT. *)
let runtime_lane_label =
  Boundary_redaction.to_string Boundary_redaction.runtime_model_label

let turn_cost result =
  let usage_trust_for_cost =
    KUM.classify_usage_trust
      ~usage_reported:result.Keeper_agent_run.usage_reported
      ~usage:result.usage
      ~context_max:0
  in
  KUM.estimate_trusted_usage_cost_usd
    ~usage_trusted:(KUM.usage_trust_is_trusted usage_trust_for_cost)
    result.usage
;;

let apply_lifecycle ~config ~base_dir ~meta ~final_execution ~current_turn_blocker_info result =
  let resilience_handles = KCB.post_turn_resilience_handles ~config ~meta in
  let lifecycle : KEC.post_turn_lifecycle =
    KEC.apply_post_turn_lifecycle_with_resilience_handles
      ~base_dir
      ~resilience_audit_store:resilience_handles.resilience_audit_store
      ~resilience_strategy_executor:resilience_handles.resilience_strategy_executor
      ~on_compaction_started:(fun () ->
        KEC.dispatch_keeper_phase_event
          ~config
          ~origin:Keeper_registry.Post_turn_lifecycle
          ~keeper_name:meta.Keeper_types.name
          Keeper_state_machine.Compaction_started)
      ~on_handoff_started:(fun () ->
        KEC.dispatch_keeper_phase_event
          ~config
          ~origin:Keeper_registry.Post_turn_lifecycle
          ~keeper_name:meta.Keeper_types.name
          Keeper_state_machine.Handoff_started)
      ~meta
      ~model:result.Keeper_agent_run.model_used
      ~primary_model_max_tokens:final_execution.KCB.max_context
      ~current_turn_blocker_info
      ~checkpoint:result.checkpoint
    |> resilience_handles.sync_lifecycle_meta
  in
  KEC.dispatch_post_turn_lifecycle_events
    ~config
    ~keeper_name:meta.Keeper_types.name
    lifecycle;
  lifecycle
;;

let apply_loop_detectors ~config updated_meta result =
  let updated_meta =
    match
      Keeper_stay_silent_loop_detector.record_turn
        ~keeper_name:updated_meta.Keeper_types.name
        ~speech_act:updated_meta.Keeper_types.runtime.last_speech_act
    with
    | Keeper_stay_silent_loop_detector.Normal -> updated_meta
    | Keeper_stay_silent_loop_detector.Loop_detected { streak; threshold } ->
      Keeper_unified_turn_stay_silent.mark_loop_detected
        ~config
        updated_meta
        ~streak
        ~threshold
    | Keeper_stay_silent_loop_detector.Loop_reset { previous_streak; was_latched } ->
      Keeper_unified_turn_stay_silent.clear_if_recovered
        ~config
        updated_meta
        ~previous_streak
        ~was_latched
  in
  let turn_effect =
    let calls = result.Keeper_agent_run.tool_calls in
    if calls = []
    then Keeper_tool_disclosure.Streak_increment
    else
      let effects =
        List.map
          (fun (detail : Keeper_agent_run.tool_call_detail) ->
             Keeper_tool_disclosure.classify_tool_progress_with_outcome
               detail.tool_name detail.typed_outcome)
          calls
      in
      if List.for_all
        (function Keeper_tool_disclosure.Streak_increment -> true | _ -> false)
        effects
      then Keeper_tool_disclosure.Streak_increment
      else
        match
          List.find_opt
            (function
              | Keeper_tool_disclosure.Streak_reset_and_empty_queue_sleep _ -> true
              | _ -> false)
            effects
        with
        | Some (Keeper_tool_disclosure.Streak_reset_and_empty_queue_sleep { reason }) ->
            Keeper_tool_disclosure.Streak_reset_and_empty_queue_sleep { reason }
        | _ -> Keeper_tool_disclosure.Streak_reset
  in
  Keeper_passive_loop_detector.record_turn_effect
    ~keeper_name:updated_meta.Keeper_types.name
    turn_effect;
  updated_meta
;;
