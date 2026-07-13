(** Success-path post-processing for [Keeper_unified_turn]. *)

module KCB = Keeper_turn_runtime_budget
module KEC = Keeper_context_runtime
module KUM = Keeper_unified_metrics
open Keeper_meta_contract

(* RFC-0132 PR-2: success-path keeper-facing metric label = external boundary; redact via SSOT. *)
let runtime_lane_label = Boundary_redaction.to_string Boundary_redaction.runtime_lane_label

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

type terminal_outcome =
  | Terminal_done
  | Terminal_checkpoint
  | Terminal_input_required

type handle_result =
  | Completed of Keeper_meta_contract.keeper_meta

let acknowledge_pending_messages
      (meta : Keeper_meta_contract.keeper_meta)
      (observation : Keeper_world_observation.world_observation)
  =
  match List.rev observation.pending_messages with
  | [] -> meta
  | latest :: _ ->
    { meta with
      runtime =
        { meta.runtime with message_scope_ack_id = Some latest.message_id }
    }
;;

let terminal_outcome_of_result result =
  match result.Keeper_agent_run.stop_reason with
  | Runtime_agent.Completed -> Terminal_done
  | Runtime_agent.InputRequired _ -> Terminal_input_required
  | Runtime_agent.TurnBudgetExhausted _
  | Runtime_agent.MutationBoundaryReached _
  | Runtime_agent.Yielded_to_chat_waiting _
  | Runtime_agent.Yielded_to_durable_stimulus _
  | Runtime_agent.ToolFailureRecoveryDeferred _ ->
    Terminal_checkpoint
;;

let terminal_outcome_is_completed_turn _ = true
;;

let terminal_outcome_to_activity_kind = function
  | Terminal_done | Terminal_checkpoint -> "keeper.turn_completed"
  | Terminal_input_required -> "keeper.turn_input_required"

let terminal_outcome_to_label = function
  | Terminal_done -> "done"
  | Terminal_checkpoint -> "checkpoint"
  | Terminal_input_required -> "input_required"

let terminal_outcome_to_log_label = function
  | Terminal_done -> "OK"
  | Terminal_checkpoint -> "checkpoint"
  | Terminal_input_required -> "input_required"

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
      ~terminal_outcome
  =
  let any_pending =
    observation.Keeper_world_observation.pending_messages <> []
    || observation.pending_board_events <> []
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
      ~count_completed_turn:(terminal_outcome_is_completed_turn terminal_outcome)
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
      ~turn_mode_label
      ~(lifecycle : KEC.post_turn_lifecycle)
      ~wall_tokens_per_second
      ~terminal_outcome
  =
  try
    let activity_kind = terminal_outcome_to_activity_kind terminal_outcome in
    let cache_miss_input_tokens =
      Keeper_hooks_oas.cache_miss_input_tokens
        ~input_tokens:result.Keeper_agent_run.usage.input_tokens
        ~cache_creation_input_tokens:result.usage.cache_creation_input_tokens
        ~cache_read_input_tokens:result.usage.cache_read_input_tokens
    in
    let event =
      Activity_graph.emit
        config
        ~actor:{ kind = "agent"; id = updated_meta.Keeper_meta_contract.agent_name }
        ~kind:activity_kind
        ~payload:
          (`Assoc
              ([ "keeper_name", `String updated_meta.name
               ; "terminal_outcome", `String (terminal_outcome_to_label terminal_outcome)
               ; ( "input_tokens"
                 , if result.usage_reported then `Int result.Keeper_agent_run.usage.input_tokens else `Null )
               ; ( "output_tokens"
                 , if result.usage_reported then `Int result.usage.output_tokens else `Null )
               ; ( "cache_creation_tokens"
                 , if result.usage_reported
                   then `Int result.usage.cache_creation_input_tokens
                   else `Null )
               ; ( "cache_read_tokens"
                 , if result.usage_reported then `Int result.usage.cache_read_input_tokens else `Null )
               ; ( "cache_miss_input_tokens"
                 , if result.usage_reported then `Int cache_miss_input_tokens else `Null )
               ; ("cost_usd", if result.usage_reported then `Float turn_cost else `Null)
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
      "%s: activity graph %s emitted seq=%d"
      updated_meta.name
      activity_kind
      event.seq
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Keeper_turn_helpers.report_keeper_cycle_side_effect_issue
      ~config
      ~keeper_name:updated_meta.name
      ~side_effect:"activity graph turn terminal emit"
      (Printexc.to_string exn)
;;

let emit_usage_metrics_and_log
      ~updated_meta
      ~result
      ~latency_ms
      ~usage_trust
      ~turn_mode_label
      ~(lifecycle : KEC.post_turn_lifecycle)
      ~terminal_outcome
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
    | Runtime_agent.Yielded_to_chat_waiting { turns_used } ->
      Printf.sprintf "yielded_to_chat_waiting(%d)" turns_used
    | Runtime_agent.Yielded_to_durable_stimulus { turns_used } ->
      Printf.sprintf "yielded_to_durable_stimulus(%d)" turns_used
    | Runtime_agent.InputRequired { turns_used; _ } ->
      Printf.sprintf "input_required(%d)" turns_used
    | Runtime_agent.ToolFailureRecoveryDeferred { turns_used; _ } ->
      Printf.sprintf "tool_failure_recovery_deferred(%d)" turns_used
  in
  let outcome_label =
    match terminal_outcome with
    | Terminal_done -> "success"
    | Terminal_input_required -> "input_required"
    | Terminal_checkpoint ->
      (match result.stop_reason with
       | Runtime_agent.TurnBudgetExhausted _ -> "budget_exhausted"
       | Runtime_agent.MutationBoundaryReached _ -> "mutation_boundary"
       | Runtime_agent.Yielded_to_chat_waiting _ -> "yielded_to_chat_waiting"
       | Runtime_agent.Yielded_to_durable_stimulus _ ->
         "yielded_to_durable_stimulus"
       | Runtime_agent.InputRequired _ -> "input_required"
       | Runtime_agent.ToolFailureRecoveryDeferred _ ->
         "tool_failure_recovery_deferred"
       | Runtime_agent.Completed -> "success")
  in
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string Turns)
    ~labels:[ "keeper", updated_meta.name; "outcome", outcome_label ]
    ();
  if result.usage_reported
  then (
    (* Otel counters are monotonic. Invalid negative provider counters remain
       in JSONL/meta/log evidence and are described by [usage_trust]; they are
       not submitted as negative counter deltas. *)
    if result.usage.input_tokens >= 0
    then
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string InputTokens)
      ~labels:[ "keeper", updated_meta.name; "model", runtime_lane_label ]
      ~delta:(float_of_int result.usage.input_tokens)
      ();
    if result.usage.output_tokens >= 0
    then
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
        ());
  (match usage_trust with
   | Keeper_usage_trust.Usage_untrusted reasons ->
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
      lifecycle.KEC.context_max
   | Keeper_usage_trust.Usage_missing ->
     Log.Keeper.info
       "%s: keeper usage telemetry missing runtime_lane=%s"
       updated_meta.name
       runtime_lane_label
   | Keeper_usage_trust.Usage_trusted -> ());
  let logged_total_tokens =
    if result.usage_reported
    then result.usage.input_tokens + result.usage.output_tokens
    else 0
  in
  Log.Keeper.info
    "%s: keeper cycle %s runtime_lane=%s tokens=%d latency=%dms mode=%s stop=%s"
    updated_meta.name
    (terminal_outcome_to_log_label terminal_outcome)
    runtime_lane_label
    logged_total_tokens
    latency_ms
    turn_mode_label
    outcome_str
;;

type decision_outcome =
  | Decision_success
  | Decision_checkpoint
  | Decision_input_required

let decision_outcome_of_terminal_outcome = function
  | Terminal_done -> Decision_success
  | Terminal_checkpoint -> Decision_checkpoint
  | Terminal_input_required -> Decision_input_required

let decision_outcome_to_label = function
  | Decision_success -> "success"
  | Decision_checkpoint -> "checkpoint"
  | Decision_input_required -> "input_required"

let terminal_reason_of_outcome result = function
  | Terminal_done -> Keeper_turn_terminal.success ()
  | Terminal_input_required ->
    Keeper_turn_terminal.of_disposition
      ~source:"runtime_stop_reason"
      Keeper_turn_disposition.Input_required
  | Terminal_checkpoint ->
    (match result.Keeper_agent_run.stop_reason with
     | Runtime_agent.TurnBudgetExhausted { turns_used; limit } ->
       Keeper_turn_terminal.of_disposition
         ~source:"runtime_stop_reason"
         (Keeper_turn_disposition.Turn_budget_exhausted
            { detail = None; used = turns_used; limit })
     | Runtime_agent.MutationBoundaryReached _
     | Runtime_agent.Yielded_to_chat_waiting _
     | Runtime_agent.Yielded_to_durable_stimulus _
     | Runtime_agent.InputRequired _ ->
       Keeper_turn_terminal.of_disposition
         ~source:"runtime_stop_reason"
         Keeper_turn_disposition.Input_required
     | Runtime_agent.ToolFailureRecoveryDeferred _
     | Runtime_agent.Completed ->
       Keeper_turn_terminal.success ())

let persist_terminal_turn_meta
      ~config
      ~original_meta
      ~updated_meta
  =
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
     (* #22043: emit inside the [Error] arm so
        [write_meta_cycle_failures_total] stays a failure counter. It is
        summed into the dashboard failure panel (Dashboard.ml), and the
        sibling emit site (Keeper_unified_turn.ml, site=Turn_failure) only
        fires on the failure path. Previously this inc sat after the match
        and fired on every successful persist cycle, inflating the series. *)
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string WriteMetaCycleFailures)
       ~labels:
         [ "keeper", original_meta.name
         ; "site", Keeper_write_meta_cycle_failure_site.(to_label Keeper_cycle)
         ]
       ();
     if Keeper_meta_store.is_version_conflict_error msg
     then Log.Keeper.warn "write_meta lost CAS race after retries (keeper cycle): %s" msg
     else Log.Keeper.error "write_meta failed after keeper cycle: %s" msg);
  updated_meta
;;

let reset_turn_failures_for_stop_reason ~config ~updated_meta result =
  let reset_failure_state () =
    Keeper_registry.set_failure_reason
      ~base_path:config.Workspace.base_path
      updated_meta.name
      None;
    Keeper_registry.reset_turn_failures
      ~base_path:config.Workspace.base_path
      updated_meta.name;
    Health.record_success ~agent_name:updated_meta.name
  in
  match result.Keeper_agent_run.stop_reason with
  | Runtime_agent.TurnBudgetExhausted { turns_used; limit } ->
    Log.Keeper.info ~keeper_name:updated_meta.name
      "runtime reported turn budget checkpoint (%d/%d); Keeper remains healthy \
       and resumes on its next lane cycle"
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
  | Runtime_agent.Yielded_to_chat_waiting { turns_used } ->
    (* A clean, intentional yield to a parked chat, not a degraded outcome:
       clear turn-failure state and record health success, like a completed
       turn. The keeper resumes its own work on the next cycle. *)
    Log.Keeper.info ~keeper_name:updated_meta.name
      "yielded turn slot to a waiting chat request after %d turn(s), checkpoint \
       saved — will resume next cycle"
      turns_used;
    reset_failure_state ()
  | Runtime_agent.Yielded_to_durable_stimulus { turns_used } ->
    Log.Keeper.info ~keeper_name:updated_meta.name
      "yielded autonomous run for a pending durable stimulus after %d turn(s), \
       checkpoint saved — will resume next cycle"
      turns_used;
    reset_failure_state ()
  | Runtime_agent.ToolFailureRecoveryDeferred
      { turns_used; reason; tool_names } ->
    Log.Keeper.info ~keeper_name:updated_meta.name
      "typed tool-failure recovery deferred after %d turn(s), checkpoint saved \
       tools=%s reason_digest=%s"
      turns_used
      (String.concat "," tool_names)
      Digestif.SHA256.(digest_string reason |> to_hex);
    reset_failure_state ()
  | Runtime_agent.InputRequired { turns_used; request } ->
    Log.Keeper.info ~keeper_name:updated_meta.name
      "typed input required after %d turn(s), checkpoint saved request_id=%s"
      turns_used
      request.Agent_sdk.Error.request_id;
    reset_failure_state ()
  | Runtime_agent.Completed -> reset_failure_state ()
;;

module For_testing = struct
  type nonrec terminal_outcome = terminal_outcome =
    | Terminal_done
    | Terminal_checkpoint
    | Terminal_input_required

  let terminal_outcome_of_result = terminal_outcome_of_result
  let terminal_outcome_is_completed_turn = terminal_outcome_is_completed_turn

  let persist_terminal_turn_meta_for_outcome
        ~config
        ~original_meta
        ~updated_meta
        ~terminal_outcome
    =
    persist_terminal_turn_meta
      ~config
      ~original_meta
      ~updated_meta

  let reset_turn_failures_for_stop_reason = reset_turn_failures_for_stop_reason
  let acknowledge_pending_messages = acknowledge_pending_messages
end

let emit_terminal_fsm
      ~config
      ~meta
      ~keeper_turn_id
      ~updated_meta
      result
  =
  Keeper_turn_fsm.emit_transition
    ~keeper_name:meta.Keeper_meta_contract.name
    ~turn_id:keeper_turn_id
    ~prev:Keeper_turn_fsm.Streaming
    Keeper_turn_fsm.Completing;
  reset_turn_failures_for_stop_reason ~config ~updated_meta result;
  Keeper_turn_fsm.emit_transition
    ~keeper_name:meta.name
    ~turn_id:keeper_turn_id
    ~prev:Keeper_turn_fsm.Completing
    Keeper_turn_fsm.Done;
  Completed updated_meta
;;

let handle
      ~config
      ~base_dir
      ~meta
      ~turn_ctx_cell
      ~observation
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
      ~update_proactive_rt:true
      result
  in
  let updated_meta = acknowledge_pending_messages updated_meta observation in
  (* RFC-0303 Phase 3: the no-progress loop detector is retired, so the
     metrics-updated meta flows through unchanged (no loop-detection rebind). *)
  let terminal_outcome = terminal_outcome_of_result result in
  append_metrics_snapshot
    ~config
    ~meta
    ~updated_meta
    ~observation
    ~result
    ~latency_ms
    ~turn_cost
    ~lifecycle
    ~last_provider_timeout_budget
    ~terminal_outcome;
  let turn_mode = KUM.turn_mode_of_result result in
  let turn_mode_label = KUM.turn_mode_to_string turn_mode in
  let usage_trust =
    KUM.classify_usage_trust
      ~usage_reported:result.Keeper_agent_run.usage_reported
      ~usage:result.usage
  in
  let wall_tokens_per_second =
    if result.usage_reported && result.usage.output_tokens >= 0 && latency_ms > 0
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
    ~turn_mode_label
    ~lifecycle
    ~wall_tokens_per_second
    ~terminal_outcome;
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
    ~outcome:
      (decision_outcome_to_label
         (decision_outcome_of_terminal_outcome terminal_outcome))
    ~degraded_retry_applied
    ?degraded_retry_runtime
    ?fallback_reason:(Option.map Keeper_error_classify.degraded_retry_reason_to_string fallback_reason)
    ~turn_mode
    ~terminal_reason:(terminal_reason_of_outcome result terminal_outcome)
    ~result:(Some result)
    ();
  emit_usage_metrics_and_log
    ~updated_meta
    ~result
    ~latency_ms
    ~usage_trust
    ~turn_mode_label
    ~lifecycle
    ~terminal_outcome;
  (* Every terminal outcome has consumed a keeper turn id. *)
  let updated_meta =
    persist_terminal_turn_meta
      ~config
      ~original_meta:meta
      ~updated_meta
  in
  let tool_call_summaries =
    result.Keeper_agent_run.tool_calls
    |> List.map (fun (d : Keeper_agent_run.tool_call_detail) ->
       ( { tool_name = d.tool_name; outcome = d.outcome }
         : Keeper_meta_contract.tool_call_summary ))
  in
  let updated_meta =
    { updated_meta with
      runtime = { updated_meta.runtime with last_turn_tool_calls = tool_call_summaries }
    }
  in
  (* Single source of truth for success-path terminal FSM transitions.
     Completion-contract observations never rewrite a successful runtime turn
     into a failed Keeper lifecycle transition. *)
  emit_terminal_fsm
    ~config
    ~meta
    ~keeper_turn_id
    ~updated_meta
    result
;;
