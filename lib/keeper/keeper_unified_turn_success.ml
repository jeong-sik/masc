(** Success-path post-processing for [Keeper_unified_turn]. *)

module KCB = Keeper_turn_cascade_budget
module KEC = Keeper_exec_context
module KUM = Keeper_unified_metrics
module Social = Keeper_social_model

let runtime_lane_label = "runtime"

let turn_cost result =
  let used_model_id = Keeper_agent_run.surface_model_used result in
  let resolved_model_id = Keeper_agent_run.surface_resolved_model_id result in
  let usage_trust_for_cost =
    KUM.classify_usage_trust
      ~usage_reported:result.Keeper_agent_run.usage_reported
      ~usage:result.usage
      ~model_used:used_model_id
      ~resolved_model_id
      ~context_max:0
  in
  KUM.estimate_trusted_usage_cost_usd
    ~usage_trusted:(KUM.usage_trust_is_trusted usage_trust_for_cost)
    ~model:used_model_id
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
  let progress_class =
    let names = result.Keeper_agent_run.tools_used in
    if names = []
    then "passive_status"
    else if
      List.for_all
        (fun name ->
           match Keeper_tool_disclosure.classify_tool_progress name with
           | Keeper_tool_disclosure.Execution
           | Keeper_tool_disclosure.Completion -> false
           | Keeper_tool_disclosure.Passive_status
           | Keeper_tool_disclosure.Claim_context -> true)
        names
    then "passive_status"
    else "execution"
  in
  Keeper_passive_loop_detector.record_turn
    ~keeper_name:updated_meta.Keeper_types.name
    ~progress_class;
  updated_meta
;;

let append_metrics_snapshot
      ~config
      ~meta
      ~updated_meta
      ~observation
      ~result
      ~latency_ms
      ~semaphore_wait_ms:_
      ~turn_cost
      ~(lifecycle : KEC.post_turn_lifecycle)
      ~last_timeout_budget
  =
  try
    let any_pending =
      observation.Keeper_world_observation.pending_mentions <> []
      || observation.pending_board_events <> []
      || observation.pending_scope_messages <> []
    in
    let channel = if any_pending then "turn" else "scheduled_autonomous" in
    if any_pending
    then Keeper_turn_helpers.post_assign_task ~any_pending ~channel
    else Keeper_turn_helpers.post_empty_queue_sleep ~any_pending ~channel;
    KUM.append_metrics_snapshot
      ~config
      ~meta:updated_meta
      ~observation
      ~result
      ~latency_ms
      ~turn_cost
      ~turn_generation:lifecycle.KEC.turn_generation
      ~channel
      ~snapshot_source:"keeper_unified_turn"
      ~context_ratio:lifecycle.context_ratio
      ~context_tokens:lifecycle.context_tokens
      ~context_max:lifecycle.context_max
      ~message_count:lifecycle.message_count
      ~compaction:lifecycle.compaction
      ~handoff_json:lifecycle.handoff_json
      ?timeout_budget_json:
        (Option.map KCB.oas_timeout_budget_resolution_to_yojson last_timeout_budget)
      ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    let channel =
      if
        observation.pending_mentions <> []
        || observation.pending_board_events <> []
        || observation.pending_scope_messages <> []
      then "turn"
      else "scheduled_autonomous"
    in
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_metric_emit_dropped
      ~labels:
        [ "keeper", updated_meta.Keeper_types.name
        ; "channel", channel
        ; "site", Keeper_metric_emit_dropped_site.(to_label Keeper_unified_turn)
        ]
      ();
    Log.Keeper.error
      "write metrics snapshot failed after keeper cycle: %s"
      (Printexc.to_string exn);
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_turn_metrics_snapshot_failures
      ~labels:
        [ "keeper", meta.Keeper_types.name
        ; "site", Keeper_turn_metrics_snapshot_failure_site.(to_label Post_cycle)
        ]
      ()
;;

let emit_activity_graph
      ~config
      ~updated_meta
      ~result
      ~latency_ms
      ~turn_cost
      ~usage_trust
      ~usage_trusted
      ~turn_mode_label
      ~(lifecycle : KEC.post_turn_lifecycle)
      ~wall_tokens_per_second
  =
  try
    let event =
      Activity_graph.emit
        config
        ~actor:{ kind = "agent"; id = updated_meta.Keeper_types.agent_name }
        ~kind:"keeper.turn_completed"
        ~payload:
          (`Assoc
              ([ "keeper_name", `String updated_meta.name
               ; ( "input_tokens"
                 , if usage_trusted then `Int result.Keeper_agent_run.usage.input_tokens else `Null )
               ; ( "output_tokens"
                 , if usage_trusted then `Int result.usage.output_tokens else `Null )
               ; ( "cache_creation_tokens"
                 , if usage_trusted
                   then `Int result.usage.cache_creation_input_tokens
                   else `Null )
               ; ( "cache_read_tokens"
                 , if usage_trusted then `Int result.usage.cache_read_input_tokens else `Null )
               ; ("cost_usd", if usage_trusted then `Float turn_cost else `Null)
               ; "latency_ms", `Int latency_ms
               ; "model_used", `Null
               ; "resolved_model_id", `Null
               ; "usage_trust", `String (KUM.usage_trust_to_string usage_trust)
               ; ( "usage_anomaly_reasons"
                 , `List
                     (List.map
                        (fun reason -> `String reason)
                        (KUM.usage_trust_reasons usage_trust)) )
               ; "turn_mode", `String turn_mode_label
               ; "context_ratio", `Float lifecycle.KEC.context_ratio
               ; ( "tools_used"
                 , `List (List.map (fun s -> `String s) result.tools_used) )
               ]
               @ (match wall_tokens_per_second with
                  | Some v -> [ "tokens_per_second", `Float v ]
                  | None -> [])
               @
               match result.inference_telemetry with
               | Some t ->
                 (match t.reasoning_tokens with
                  | Some n -> [ "reasoning_tokens", `Int n ]
                  | None -> [])
                 @
                   (match t.timings with
                   | Some ti ->
                     (match ti.prompt_per_second with
                      | Some v -> [ "prompt_per_second", `Float v ]
                      | None -> [])
                     @
                       (match ti.predicted_per_second with
                       | Some v -> [ "hw_decode_tokens_per_second", `Float v ]
                       | None -> [])
                   | None -> [])
               | None -> []))
        ~tags:[ "keeper"; "turn"; "metrics" ]
        ()
    in
    Log.Keeper.debug
      "%s: activity graph turn_completed emitted seq=%d"
      updated_meta.Keeper_types.name
      event.seq
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Keeper_turn_helpers.report_keeper_cycle_side_effect_issue
      ~config
      ~keeper_name:updated_meta.Keeper_types.name
      ~side_effect:"activity graph turn_completed emit"
      (Printexc.to_string exn)
;;

let record_accountability ~config ~updated_meta ~social_state ~result claim =
  let trace_id = Keeper_id.Trace_id.to_string updated_meta.Keeper_types.runtime.trace_id in
  let validated_evidence = KUM.visible_run_validation result in
  let strong_evidence =
    KUM.has_substantive_tool_calls result.Keeper_agent_run.tools_used
    || Option.is_some validated_evidence
  in
  Keeper_accountability.record_completion_claim
    config
    ~keeper_name:updated_meta.name
    ~agent_name:updated_meta.agent_name
    ~trace_id
    ~turn_number:updated_meta.runtime.usage.total_turns
    ~subject:claim.Social.subject
    ?task_id:claim.task_id
    ~evidence_refs:claim.evidence_refs
    ~surface:(Social.delivery_surface_to_string social_state.Social.delivery_surface)
    ~strong_evidence
    ~strong_evidence_refs:
      (KUM.accountability_evidence_refs
         ~trace_id
         ~turn_number:updated_meta.runtime.usage.total_turns
         ~result
         ~validated_evidence)
    ()
;;

let emit_usage_metrics_and_log
      ~updated_meta
      ~result
      ~latency_ms
      ~usage_trust
      ~usage_trusted
      ~turn_mode_label
      ~(lifecycle : KEC.post_turn_lifecycle)
  =
  let outcome_str =
    match result.Keeper_agent_run.stop_reason with
    | Cascade_runner.Completed -> "completed"
    | Cascade_runner.TurnBudgetExhausted { turns_used; limit; _ } ->
      Printf.sprintf "budget_exhausted(%d/%d)" turns_used limit
    | Cascade_runner.MutationBoundaryReached { turns_used; tool_name } ->
      (match tool_name with
       | Some tool -> Printf.sprintf "mutation_boundary(%d:%s)" turns_used tool
       | None -> Printf.sprintf "mutation_boundary(%d)" turns_used)
  in
  let outcome_label =
    match result.stop_reason with
    | Cascade_runner.Completed -> "success"
    | Cascade_runner.TurnBudgetExhausted _ -> "budget_exhausted"
    | Cascade_runner.MutationBoundaryReached _ -> "mutation_boundary"
  in
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_turns
    ~labels:[ "keeper_name", updated_meta.Keeper_types.name; "outcome", outcome_label ]
    ();
  if usage_trusted
  then (
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_input_tokens
      ~labels:[ "keeper_name", updated_meta.name; "model", runtime_lane_label ]
      ~delta:(float_of_int result.usage.input_tokens)
      ();
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_output_tokens
      ~labels:[ "keeper_name", updated_meta.name; "model", runtime_lane_label ]
      ~delta:(float_of_int result.usage.output_tokens)
      ();
    if result.usage.cache_creation_input_tokens > 0
    then
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_cache_creation_tokens
        ~labels:[ "keeper_name", updated_meta.name; "model", runtime_lane_label ]
        ~delta:(float_of_int result.usage.cache_creation_input_tokens)
        ();
    if result.usage.cache_read_input_tokens > 0
    then
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_cache_read_tokens
        ~labels:[ "keeper_name", updated_meta.name; "model", runtime_lane_label ]
        ~delta:(float_of_int result.usage.cache_read_input_tokens)
        ())
  else (
    let reasons =
      match KUM.usage_trust_reasons usage_trust with
      | [] -> [ KUM.usage_trust_to_string usage_trust ]
      | reasons -> reasons
    in
    List.iter
      (fun reason ->
         Prometheus.inc_counter
           Keeper_metrics.metric_keeper_usage_anomalies
           ~labels:
             [ "keeper_name", updated_meta.name
             ; "model", runtime_lane_label
             ; "reason", reason
             ]
           ())
      reasons;
    let log_usage =
      if Keeper_usage_trust.warns_operator usage_trust
      then Log.Keeper.warn
      else Log.Keeper.info
    in
    log_usage
      "%s: keeper usage telemetry %s runtime_lane=%s reasons=%s input=%d output=%d \
       context_max=%d"
      updated_meta.name
      (if Keeper_usage_trust.warns_operator usage_trust
       then "untrusted"
       else "unavailable")
      runtime_lane_label
      (String.concat "," reasons)
      result.usage.input_tokens
      result.usage.output_tokens
      lifecycle.KEC.context_max);
  let logged_total_tokens =
    if usage_trusted then result.usage.input_tokens + result.usage.output_tokens else 0
  in
  Log.Keeper.info
    "%s: keeper cycle OK runtime_lane=%s tokens=%d latency=%dms mode=%s stop=%s"
    updated_meta.name
    runtime_lane_label
    logged_total_tokens
    latency_ms
    turn_mode_label
    outcome_str
;;

let persist_success_meta ~config ~original_meta ~updated_meta =
  let updated_meta =
    if updated_meta.Keeper_types.auto_resume_after_sec <> None
    then { updated_meta with auto_resume_after_sec = None }
    else updated_meta
  in
  (match
     Keeper_types.write_meta_with_merge
       ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
       config
       updated_meta
   with
   | Ok () -> ()
   | Error msg ->
     Prometheus.inc_counter
       Keeper_metrics.metric_keeper_write_meta_failures
       ~labels:
         [ "keeper", updated_meta.name
         ; ( "phase"
           , if Keeper_types.is_version_conflict_error msg
             then "keeper_cycle_cas_race"
             else "keeper_cycle" )
         ]
       ();
     if Keeper_types.is_version_conflict_error msg
     then Log.Keeper.warn "write_meta lost CAS race after retries (keeper cycle): %s" msg
     else Log.Keeper.error "write_meta failed after keeper cycle: %s" msg);
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_write_meta_cycle_failures
    ~labels:
      [ "keeper", original_meta.Keeper_types.name
      ; "site", Keeper_write_meta_cycle_failure_site.(to_label Keeper_cycle)
      ]
    ();
  updated_meta
;;

let reset_turn_failures_for_stop_reason ~config ~updated_meta result =
  match result.Keeper_agent_run.stop_reason with
  | Cascade_runner.TurnBudgetExhausted { turns_used; limit } ->
    Log.Keeper.info
      "keeper:%s turn budget exhausted (%d/%d), checkpoint saved — will resume next cycle"
      updated_meta.Keeper_types.name
      turns_used
      limit;
    Keeper_registry.reset_turn_failures
      ~base_path:config.Coord.base_path
      updated_meta.name
  | Cascade_runner.MutationBoundaryReached { tool_name; _ } ->
    Log.Keeper.info
      "keeper:%s mutation boundary reached after %s, checkpoint saved — will resume next cycle"
      updated_meta.name
      (match tool_name with
       | Some tool -> tool
       | None -> "committed tool");
    Keeper_registry.reset_turn_failures
      ~base_path:config.base_path
      updated_meta.name
  | Cascade_runner.Completed ->
    Keeper_registry.reset_turn_failures
      ~base_path:config.base_path
      updated_meta.name
;;

let handle
      ~config
      ~base_dir
      ~meta
      ~observation
      ~previous_social_state
      ~final_execution
      ~latency_ms
      ~semaphore_wait_ms
      ~degraded_retry_applied
      ~degraded_retry_cascade
      ~fallback_reason
      ~last_timeout_budget
      ~current_turn_blocker_info
      ~keeper_turn_id
      result
  =
  let explicit_accountability_claim = Social.extract_accountability_claim result in
  let result, social_state, social_transition_reason =
    Social.apply_to_result ~meta ~observation ~previous_state:previous_social_state result
  in
  let turn_cost = turn_cost result in
  let lifecycle =
    apply_lifecycle
      ~config
      ~base_dir
      ~meta
      ~final_execution
      ~current_turn_blocker_info
      result
  in
  let updated_meta =
    KUM.update_metrics_from_result
      lifecycle.KEC.updated_meta
      ~latency_ms
      ~observation
      ~social_state
      ~social_transition_reason:(Social.transition_reason_to_string social_transition_reason)
      ~context_max:lifecycle.context_max
      ~update_proactive_rt:true
      result
  in
  let updated_meta = apply_loop_detectors ~config updated_meta result in
  append_metrics_snapshot
    ~config
    ~meta
    ~updated_meta
    ~observation
    ~result
    ~latency_ms
    ~semaphore_wait_ms
    ~turn_cost
    ~lifecycle
    ~last_timeout_budget;
  let turn_mode = KUM.turn_mode_of_result result in
  let turn_mode_label = KUM.turn_mode_to_string turn_mode in
  let model_used = Keeper_agent_run.surface_model_used result in
  let resolved_model_id = Keeper_agent_run.surface_resolved_model_id result in
  let usage_trust =
    KUM.classify_usage_trust
      ~usage_reported:result.Keeper_agent_run.usage_reported
      ~usage:result.usage
      ~model_used
      ~resolved_model_id
      ~context_max:lifecycle.context_max
  in
  let usage_trusted = KUM.usage_trust_is_trusted usage_trust in
  let wall_tokens_per_second =
    if usage_trusted && latency_ms > 0
    then Some (float_of_int result.usage.output_tokens /. (float_of_int latency_ms /. 1000.0))
    else None
  in
  emit_activity_graph
    ~config
    ~updated_meta
    ~result
    ~latency_ms
    ~turn_cost
    ~usage_trust
    ~usage_trusted
    ~turn_mode_label
    ~lifecycle
    ~wall_tokens_per_second;
  KUM.broadcast_lifecycle_events
    ~name:updated_meta.name
    ~turn_generation:lifecycle.turn_generation
    ~compaction:lifecycle.compaction
    ~handoff_json:lifecycle.handoff_json;
  KUM.append_decision_record
    ~config
    ~meta:updated_meta
    ~observation
    ~latency_ms
    ~semaphore_wait_ms
    ~outcome:"success"
    ~degraded_retry_applied
    ?degraded_retry_cascade
    ?fallback_reason:(Option.map Keeper_error_classify.degraded_retry_reason_to_string fallback_reason)
    ~turn_mode
    ~social_state
    ~result:(Some result)
    ();
  (match explicit_accountability_claim with
   | Some claim -> record_accountability ~config ~updated_meta ~social_state ~result claim
   | None -> ());
  emit_usage_metrics_and_log
    ~updated_meta
    ~result
    ~latency_ms
    ~usage_trust
    ~usage_trusted
    ~turn_mode_label
    ~lifecycle;
  let updated_meta = persist_success_meta ~config ~original_meta:meta ~updated_meta in
  Keeper_turn_fsm.emit_transition
    ~keeper_name:meta.Keeper_types.name
    ~turn_id:keeper_turn_id
    ~prev:Keeper_turn_fsm.Streaming
    Keeper_turn_fsm.Completing;
  reset_turn_failures_for_stop_reason ~config ~updated_meta result;
  Keeper_turn_fsm.emit_transition
    ~keeper_name:meta.name
    ~turn_id:keeper_turn_id
    ~prev:Keeper_turn_fsm.Completing
    Keeper_turn_fsm.Done;
  updated_meta
;;
