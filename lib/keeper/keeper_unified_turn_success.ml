(** Success-path post-processing for [Keeper_unified_turn]. *)

module KCB = Keeper_turn_runtime_budget
module KEC = Keeper_context_runtime
module KUM = Keeper_unified_metrics
module Social = Keeper_social_model
open Keeper_meta_contract

(* RFC-0132 PR-2: success-path keeper-facing metric label = external boundary; redact via SSOT. *)
let runtime_lane_label =
  Boundary_redaction.to_string Boundary_redaction.runtime_model_label

(* cost_usd is accounted independently of token-count trust (token⊥cost), so the
   turn cost no longer needs a usage-trust classification. *)
let turn_cost result = KUM.estimate_usage_cost_usd result.Keeper_agent_run.usage
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
          ~keeper_name:meta.name
          Keeper_state_machine.Compaction_started)
      ~on_handoff_started:(fun () ->
        KEC.dispatch_keeper_phase_event
          ~config
          ~origin:Keeper_registry.Post_turn_lifecycle
          ~keeper_name:meta.name
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
    ~keeper_name:meta.name
    lifecycle;
  lifecycle
;;

let apply_loop_detectors ~config ~social_state updated_meta result =
  (* RFC-0239 §3 R3: feed the loop detector a semantic no-progress verdict
     instead of the literal speech_act. A turn makes progress if it produced
     durable evidence (substantive tool calls or validated output); a turn that
     only posts to peers (board/comment/broadcast) or stays silent without such
     evidence accrues the streak. The old speech_act="stay_silent" check reset
     the streak whenever a keeper *posted* its "nothing to do" conclusion, so a
     cluster that thrashed by re-posting never tripped the detector. *)
  let strong_evidence =
    KUM.has_substantive_tool_calls (Keeper_agent_result.tool_names result)
    || Option.is_some (KUM.visible_run_validation result)
  in
  let surface_requires_evidence =
    match social_state.Social.delivery_surface with
    | Social.Board_post | Social.Board_comment | Social.Broadcast_surface
    | Social.Silent -> true
    | Social.Visible_reply | Social.Task_claim_surface -> false
  in
  let made_progress =
    Keeper_no_progress_loop_detector.turn_made_progress
      ~strong_evidence
      ~surface_requires_evidence
  in
  match
    Keeper_no_progress_loop_detector.record_turn
      ~keeper_name:updated_meta.Keeper_meta_contract.name
      ~made_progress
  with
  | Keeper_no_progress_loop_detector.Normal -> updated_meta
  | Keeper_no_progress_loop_detector.Loop_detected { streak; threshold } ->
    Keeper_unified_turn_no_progress.mark_loop_detected
      ~config
      updated_meta
      ~streak
      ~threshold
  | Keeper_no_progress_loop_detector.Loop_reset { previous_streak; was_latched } ->
    Keeper_unified_turn_no_progress.clear_if_recovered
      ~config
      updated_meta
      ~previous_streak
      ~was_latched
;;

let append_metrics_snapshot
      ~config
      ~meta
      ~updated_meta
      ~observation
      ~result
      ~latency_ms
      ~turn_cost
      ~(lifecycle : KEC.post_turn_lifecycle)
      ~last_provider_timeout_budget
  =
  let any_pending =
    observation.Keeper_world_observation.pending_mentions <> []
    || observation.pending_board_events <> []
    || observation.pending_scope_messages <> []
  in
  (* Single typed channel for the whole cycle: post helpers + the metrics
     snapshot + the failure-path label all derive from one value, so the
     reactive/autonomous decision can no longer drift between sites. *)
  let channel =
    if any_pending
    then Keeper_world_observation.Reactive
    else Keeper_world_observation.Scheduled_autonomous
  in
  let channel_tag = Keeper_world_observation.channel_to_string channel in
  try
    if any_pending
    then Keeper_turn_helpers.post_assign_task ~any_pending ~channel:channel_tag
    else Keeper_turn_helpers.post_empty_queue_sleep ~any_pending ~channel:channel_tag;
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
      ?provider_timeout_plan_json:
        (Option.map KCB.provider_timeout_budget_to_yojson last_provider_timeout_budget)
      ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string MetricEmitDropped)
      ~labels:
        [ "keeper", updated_meta.name
        ; "channel", channel_tag
        ; "site", Keeper_metric_emit_dropped_site.(to_label Keeper_unified_turn)
        ]
      ();
    Log.Keeper.error
      "write metrics snapshot failed after keeper cycle: %s"
      (Printexc.to_string exn);
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string TurnMetricsSnapshotFailures)
      ~labels:
        [ "keeper", meta.Keeper_meta_contract.name
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
        ~actor:{ kind = "agent"; id = updated_meta.Keeper_meta_contract.agent_name }
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
      updated_meta.name
      event.seq
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Keeper_turn_helpers.report_keeper_cycle_side_effect_issue
      ~config
      ~keeper_name:updated_meta.name
      ~side_effect:"activity graph turn_completed emit"
      (Printexc.to_string exn)
;;

let record_accountability ~config ~updated_meta ~social_state ~result claim =
  let trace_id = Keeper_id.Trace_id.to_string updated_meta.runtime.trace_id in
  let validated_evidence = KUM.visible_run_validation result in
  let strong_evidence =
    KUM.has_substantive_tool_calls (Keeper_agent_result.tool_names result)
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
    | Runtime_agent.Completed -> "completed"
    | Runtime_agent.TurnBudgetExhausted { turns_used; limit; _ } ->
      Printf.sprintf "budget_exhausted(%d/%d)" turns_used limit
    | Runtime_agent.MutationBoundaryReached { turns_used; tool_name } ->
      (match tool_name with
       | Some tool -> Printf.sprintf "mutation_boundary(%d:%s)" turns_used tool
       | None -> Printf.sprintf "mutation_boundary(%d)" turns_used)
  in
  let outcome_label =
    match result.stop_reason with
    | Runtime_agent.Completed -> "success"
    | Runtime_agent.TurnBudgetExhausted _ -> "budget_exhausted"
    | Runtime_agent.MutationBoundaryReached _ -> "mutation_boundary"
  in
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string Turns)
    ~labels:[ "keeper", updated_meta.name; "outcome", outcome_label ]
    ();
  if usage_trusted
  then (
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string InputTokens)
      ~labels:[ "keeper", updated_meta.name; "model", runtime_lane_label ]
      ~delta:(float_of_int result.usage.input_tokens)
      ();
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string OutputTokens)
      ~labels:[ "keeper", updated_meta.name; "model", runtime_lane_label ]
      ~delta:(float_of_int result.usage.output_tokens)
      ();
    if result.usage.cache_creation_input_tokens > 0
    then
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string CacheCreationTokens)
        ~labels:[ "keeper", updated_meta.name; "model", runtime_lane_label ]
        ~delta:(float_of_int result.usage.cache_creation_input_tokens)
        ();
    if result.usage.cache_read_input_tokens > 0
    then
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string CacheReadTokens)
        ~labels:[ "keeper", updated_meta.name; "model", runtime_lane_label ]
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
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string UsageAnomalies)
           ~labels:
             [ "keeper", updated_meta.name
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
    if updated_meta.auto_resume_after_sec <> None
    then { updated_meta with auto_resume_after_sec = None }
    else updated_meta
  in
  (match
     Keeper_meta_store.write_meta_with_merge
       ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
       config
       updated_meta
   with
   | Ok () -> ()
   | Error msg ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string WriteMetaFailures)
       ~labels:
         [ "keeper", updated_meta.name
         ; ( "phase"
           , if Keeper_meta_store.is_version_conflict_error msg
             then "keeper_cycle_cas_race"
             else "keeper_cycle" )
         ]
       ();
     if Keeper_meta_store.is_version_conflict_error msg
     then Log.Keeper.warn "write_meta lost CAS race after retries (keeper cycle): %s" msg
     else Log.Keeper.error "write_meta failed after keeper cycle: %s" msg);
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string WriteMetaCycleFailures)
    ~labels:
      [ "keeper", original_meta.name
      ; "site", Keeper_write_meta_cycle_failure_site.(to_label Keeper_cycle)
      ]
    ();
  updated_meta
;;

let reset_turn_failures_for_stop_reason ~config ~updated_meta result =
  let reset_failure_state () =
    Keeper_registry.reset_turn_failures
      ~base_path:config.Workspace.base_path
      updated_meta.name;
    Health.record_success ~agent_name:updated_meta.name
  in
  match result.Keeper_agent_run.stop_reason with
  | Runtime_agent.TurnBudgetExhausted { turns_used; limit } ->
    Log.Keeper.info ~keeper_name:updated_meta.name
      "turn budget exhausted (%d/%d), checkpoint saved — will resume next cycle"
      turns_used
      limit;
    reset_failure_state ()
  | Runtime_agent.MutationBoundaryReached { tool_name; _ } ->
    Log.Keeper.info ~keeper_name:updated_meta.name
      "mutation boundary reached after %s, checkpoint saved — will resume next cycle"
      (match tool_name with
       | Some tool -> tool
       | None -> "committed tool");
    reset_failure_state ()
  | Runtime_agent.Completed -> reset_failure_state ()
;;

let handle
      ~config
      ~base_dir
      ~meta
      ~turn_ctx_cell
      ~observation
      ~previous_social_state
      ~final_execution
      ~latency_ms
      ~degraded_retry_applied
      ~degraded_retry_runtime
      ~fallback_reason
      ~last_provider_timeout_budget
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
  let updated_meta = apply_loop_detectors ~config ~social_state updated_meta result in
  append_metrics_snapshot
    ~config
    ~meta
    ~updated_meta
    ~observation
    ~result
    ~latency_ms
    ~turn_cost
    ~lifecycle
    ~last_provider_timeout_budget;
  let turn_mode = KUM.turn_mode_of_result result in
  let turn_mode_label = KUM.turn_mode_to_string turn_mode in
  let usage_trust =
    KUM.classify_usage_trust
      ~usage_reported:result.Keeper_agent_run.usage_reported
      ~usage:result.usage
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
    ~turn_ctx_cell
    ~observation
    ~latency_ms
    ~outcome:"success"
    ~degraded_retry_applied
    ?degraded_retry_runtime
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
  let tool_call_summaries =
    let max_tool_calls = 10 in
    result.Keeper_agent_run.tool_calls
    |> List.map (fun (d : Keeper_agent_run.tool_call_detail) ->
       ( { tool_name = d.tool_name; outcome = d.outcome }
         : Keeper_meta_contract.tool_call_summary ))
    |> fun l ->
    let rec take n = function [] -> [] | h :: t -> if n <= 0 then [] else h :: take (n - 1) t in
    take max_tool_calls l
  in
  let updated_meta =
    { updated_meta with
      runtime = { updated_meta.runtime with last_turn_tool_calls = tool_call_summaries }
    }
  in
  (* Single source of truth for success-path terminal FSM transitions.
     [Keeper_unified_turn.handle] is the only caller; do not add another
     Streaming -> Completing -> Done emitter on the success path. *)
  Keeper_turn_fsm.emit_transition
    ~keeper_name:meta.name
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
