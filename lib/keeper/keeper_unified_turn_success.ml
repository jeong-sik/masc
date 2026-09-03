(** Success-path post-processing for [Keeper_unified_turn]. *)

module KCB = Keeper_turn_runtime_budget
module KEC = Keeper_context_runtime
module KUM = Keeper_unified_metrics
module KTP = Keeper_terminal_effect_policy
open Keeper_meta_contract

(* RFC-0132 PR-2: success-path keeper-facing metric label = external boundary; redact via SSOT. *)
let runtime_lane_label = Boundary_redaction.to_string Boundary_redaction.runtime_lane_label

(* cost_usd is accounted independently of token-count trust (token⊥cost), so the
   turn cost no longer needs a usage-trust classification. *)
let turn_cost (resolution : Keeper_usage_resolution.t) =
  match resolution.delta with
  | Some delta -> Option.value ~default:0.0 delta.cost_usd
  | None -> 0.0
;;

let apply_lifecycle
      ~config
      ~meta
      (result : Keeper_agent_run.run_result)
  =
  let lifecycle : KEC.post_turn_lifecycle =
    KEC.apply_post_turn_lifecycle ~meta ~checkpoint:result.checkpoint
  in
  lifecycle
;;

type terminal_outcome =
  | Terminal_done
  | Terminal_checkpoint
  | Terminal_input_required

type handle_result =
  | Completed of Keeper_meta_contract.keeper_meta

type cycle_post_action =
  | Assign_task
  | Empty_queue_sleep

let post_action_of_channel = function
  | Keeper_world_observation.Reactive -> Assign_task
  | Keeper_world_observation.Scheduled_autonomous -> Empty_queue_sleep
;;

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
  | Runtime_agent.Yielded_to_operation_queued _
  | Runtime_agent.Yielded_to_durable_stimulus _
  | Runtime_agent.Yielded_after_repeated_tool_call _
  | Runtime_agent.Yielded_after_repeated_assistant_text _ ->
    Terminal_checkpoint
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
      ~channel
      ~result
      ~latency_ms
      ~usage_resolution
      ~turn_cost
      ~(lifecycle : KEC.post_turn_lifecycle)
      ~terminal_outcome
      ~execution_outcome
  =
  (* Single typed channel for the whole cycle: post helpers + the metrics
     snapshot + the failure-path label all derive from one value, so the
     reactive/autonomous decision can no longer drift between sites. *)
  let channel_tag = Keeper_world_observation.channel_to_string channel in
  KTP.run_best_effort
    ~terminal_effect:KTP.Metrics_snapshot
    ~on_error:(fun exn ->
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
        ())
    (fun () ->
       (match Keeper_execution_outcome.lane execution_outcome with
        | Keeper_execution_outcome.Direct -> ()
        | Keeper_execution_outcome.Autonomous _ ->
          (match post_action_of_channel channel with
           | Assign_task ->
             Keeper_turn_helpers.post_assign_task ~channel:channel_tag
           | Empty_queue_sleep ->
             Keeper_turn_helpers.post_empty_queue_sleep ~channel:channel_tag));
       KUM.append_metrics_snapshot
         ~config
         ~meta:updated_meta
         ~observation
         ~result
         ~latency_ms
         ~usage_resolution
         ~turn_cost
         ~channel
         ~checkpoint_bytes:lifecycle.checkpoint_bytes
         ~message_count:lifecycle.message_count
         ())
;;

let emit_activity_graph
      ~config
      ~updated_meta
      ~(result : Keeper_agent_run.run_result)
      ~usage_resolution
      ~latency_ms
      ~turn_cost
      ~usage_trust
      ~turn_mode_label
      ~(lifecycle : KEC.post_turn_lifecycle)
      ~wall_tokens_per_second
      ~terminal_outcome
  =
  KTP.run_best_effort
    ~terminal_effect:KTP.Activity_graph
    ~on_error:(fun exn ->
      Keeper_turn_helpers.report_keeper_cycle_side_effect_issue
        ~config
        ~keeper_name:updated_meta.name
        ~side_effect:(KTP.effect_label KTP.Activity_graph)
        (Printexc.to_string exn))
    (fun () ->
       let activity_kind = terminal_outcome_to_activity_kind terminal_outcome in
       let delta = usage_resolution.Keeper_usage_resolution.delta in
       let delta_field f =
         match delta with Some usage -> `Int (f usage) | None -> `Null
       in
       let cache_miss_input_tokens =
         Option.map
           (fun usage ->
              Keeper_hooks_agent_core.cache_miss_input_tokens
                ~input_tokens:usage.Keeper_usage_resolution.input_tokens
                ~cache_creation_input_tokens:usage.cache_creation_input_tokens
                ~cache_read_input_tokens:usage.cache_read_input_tokens)
           delta
       in
       let event =
         Activity_graph.emit
        config
        ~actor:{ kind = "agent"; id = updated_meta.Keeper_meta_contract.name }
        ~kind:activity_kind
        ~payload:
          (`Assoc
              ([ "keeper_name", `String updated_meta.name
               ; "terminal_outcome", `String (terminal_outcome_to_label terminal_outcome)
               ; ( "input_tokens"
                 , delta_field (fun usage -> usage.Keeper_usage_resolution.input_tokens) )
               ; ( "output_tokens"
                 , delta_field (fun usage -> usage.Keeper_usage_resolution.output_tokens) )
               ; ( "cache_creation_tokens"
                 , delta_field (fun usage -> usage.Keeper_usage_resolution.cache_creation_input_tokens) )
               ; ( "cache_read_tokens"
                 , delta_field (fun usage -> usage.Keeper_usage_resolution.cache_read_input_tokens) )
               ; ( "cache_miss_input_tokens"
                 , Option.fold ~none:`Null ~some:(fun value -> `Int value) cache_miss_input_tokens )
               ; ( "cost_usd"
                 , match delta with
                   | Some { cost_usd = Some _; _ } -> `Float turn_cost
                   | Some { cost_usd = None; _ } | None -> `Null )
               ; "usage_resolution", Keeper_usage_resolution.to_json usage_resolution
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
               ; "checkpoint_bytes", `Int lifecycle.KEC.checkpoint_bytes
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
         event.seq)
;;

let emit_usage_metrics_and_log
      ~updated_meta
      ~result
      ~usage_resolution
      ~latency_ms
      ~usage_trust
      ~turn_mode_label
      ~(lifecycle : KEC.post_turn_lifecycle)
      ~terminal_outcome
  =
  let outcome_str =
    match result.Keeper_agent_run.stop_reason with
    | Runtime_agent.Completed -> "completed"
    | Runtime_agent.Yielded_to_operation_queued { turns_used } ->
      Printf.sprintf "yielded_to_operation_queued(%d)" turns_used
    | Runtime_agent.Yielded_to_durable_stimulus { turns_used } ->
      Printf.sprintf "yielded_to_durable_stimulus(%d)" turns_used
    | Runtime_agent.Yielded_after_repeated_tool_call
        { turns_used; tool_name; repeated_count } ->
      Printf.sprintf
        "yielded_after_repeated_tool_call(%d,%s,%d)"
        turns_used
        tool_name
        repeated_count
    | Runtime_agent.Yielded_after_repeated_assistant_text
        { turns_used; repeated_count } ->
      Printf.sprintf
        "yielded_after_repeated_assistant_text(%d,%d)"
        turns_used
        repeated_count
    | Runtime_agent.InputRequired { turns_used; _ } ->
      Printf.sprintf "input_required(%d)" turns_used
  in
  let outcome_label =
    match terminal_outcome with
    | Terminal_done -> "success"
    | Terminal_input_required -> "input_required"
     | Terminal_checkpoint ->
      (match result.stop_reason with
       | Runtime_agent.Yielded_to_operation_queued _ -> "yielded_to_operation_queued"
       | Runtime_agent.Yielded_to_durable_stimulus _ ->
         "yielded_to_durable_stimulus"
       | Runtime_agent.Yielded_after_repeated_tool_call _ ->
         "yielded_after_repeated_tool_call"
       | Runtime_agent.Yielded_after_repeated_assistant_text _ ->
         "yielded_after_repeated_assistant_text"
       | Runtime_agent.InputRequired _ -> "input_required"
       | Runtime_agent.Completed -> "success")
  in
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string Turns)
    ~labels:[ "keeper", updated_meta.name; "outcome", outcome_label ]
    ();
  (match usage_resolution.Keeper_usage_resolution.delta with
   | Some usage ->
    (* Otel counters are monotonic. Invalid negative provider counters remain
       in JSONL/meta/log evidence and are described by [usage_trust]; they are
       not submitted as negative counter deltas. *)
    if usage.input_tokens >= 0
    then
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string InputTokens)
      ~labels:[ "keeper", updated_meta.name; "model", runtime_lane_label ]
      ~delta:(float_of_int usage.input_tokens)
      ();
    if usage.output_tokens >= 0
    then
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string OutputTokens)
      ~labels:[ "keeper", updated_meta.name; "model", runtime_lane_label ]
      ~delta:(float_of_int usage.output_tokens)
      ();
    if usage.cache_creation_input_tokens > 0
    then
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string CacheCreationTokens)
        ~labels:[ "keeper", updated_meta.name; "model", runtime_lane_label ]
        ~delta:(float_of_int usage.cache_creation_input_tokens)
        ();
    if usage.cache_read_input_tokens > 0
    then
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string CacheReadTokens)
        ~labels:[ "keeper", updated_meta.name; "model", runtime_lane_label ]
        ~delta:(float_of_int usage.cache_read_input_tokens)
        ()
   | None -> ());
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
      "%s: keeper usage telemetry %s runtime_lane=%s reasons=%s input=%d output=%d"
      updated_meta.name
      (if Keeper_usage_trust.warns_operator usage_trust
       then "untrusted"
       else "unavailable")
      runtime_lane_label
      (String.concat "," reasons)
      result.usage.input_tokens
      result.usage.output_tokens
   | Keeper_usage_trust.Usage_missing ->
     Log.Keeper.info
       "%s: keeper usage telemetry missing runtime_lane=%s"
       updated_meta.name
       runtime_lane_label
   | Keeper_usage_trust.Usage_trusted -> ());
  let logged_total_tokens =
    match usage_resolution.delta with
    | Some usage -> usage.input_tokens + usage.output_tokens
    | None -> 0
  in
  Log.Keeper.info
    ~category:Log.Turn
    "%s: keeper cycle %s runtime_lane=%s tokens=%d latency=%dms mode=%s stop=%s"
    updated_meta.name
    (terminal_outcome_to_log_label terminal_outcome)
    runtime_lane_label
    logged_total_tokens
    latency_ms
    turn_mode_label
    outcome_str
;;

let emit_resolved_cost_event
      ~config
      ~meta
      ~keeper_turn_id
      ~result
      ~(usage_resolution : Keeper_usage_resolution.t)
      ~usage_trust
  =
  let usage, usage_missing =
    match usage_resolution.delta with
    | Some usage -> usage, false
    | None ->
      ( { Keeper_usage_resolution.input_tokens = 0
        ; output_tokens = 0
        ; cache_creation_input_tokens = 0
        ; cache_read_input_tokens = 0
        ; cost_usd = None
        }
      , true )
  in
  Keeper_hooks_agent_core.emit_cost_event
    ~masc_root:(Common.masc_dir_from_base_path ~base_path:config.Workspace.base_path)
    ~agent_name:meta.Keeper_meta_contract.name
    ~task_id:(Option.map Keeper_id.Task_id.to_string meta.current_task_id)
    ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
    ~keeper_turn_id
    ~agent_core_turn_ordinal:result.Keeper_agent_run.final_agent_core_turn_ordinal
    ~model:result.model_used
    ~input_tokens:usage.input_tokens
    ~output_tokens:usage.output_tokens
    ~cost_usd:(Option.value ~default:0.0 usage.cost_usd)
    ~cache_creation_input_tokens:usage.cache_creation_input_tokens
    ~cache_read_input_tokens:usage.cache_read_input_tokens
    ~usage_missing
    ~usage_projection:Cost_ledger.Resolved_delta
    ~usage_trust
    ?telemetry:result.inference_telemetry
    ()
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
     | Runtime_agent.Yielded_to_operation_queued _
     | Runtime_agent.Yielded_to_durable_stimulus _
     | Runtime_agent.Yielded_after_repeated_tool_call _
     | Runtime_agent.Yielded_after_repeated_assistant_text _
     | Runtime_agent.InputRequired _ ->
       Keeper_turn_terminal.of_disposition
         ~source:"runtime_stop_reason"
         Keeper_turn_disposition.Input_required
     | Runtime_agent.Completed -> Keeper_turn_terminal.success ())

exception Owner_meta_commit_failed of string

let persist_terminal_turn_meta ~config ~original_meta ~updated_meta =
  match
    Keeper_owner_registry.commit_turn_runtime
      ~base_path:config.Workspace.base_path
      ~keeper_name:original_meta.name
      ~before:original_meta
      ~after:updated_meta
  with
  | Ok (Some committed) -> committed
  | Ok None ->
    raise
      (Owner_meta_commit_failed
         "Keeper Owner removed metadata during terminal turn commit")
  | Error error ->
    let detail = Keeper_owner_registry.command_error_to_string error in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string WriteMetaFailures)
      ~labels:[ "keeper", original_meta.name; "phase", "keeper_cycle" ]
      ();
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string WriteMetaCycleFailures)
      ~labels:
        [ "keeper", original_meta.name
        ; "site", Keeper_write_meta_cycle_failure_site.(to_label Keeper_cycle)
        ]
      ();
    raise (Owner_meta_commit_failed detail)
;;

let reset_turn_failures_for_stop_reason ~config ~updated_meta result =
  let reset_failure_state () =
    if
      Keeper_turn_failure_streak.reset
        ~base_path:config.Workspace.base_path
        ~keeper_name:updated_meta.name
    then Health.record_success ~agent_name:updated_meta.name
  in
  match result.Keeper_agent_run.stop_reason with
  | Runtime_agent.Yielded_to_operation_queued { turns_used } ->
    (* A clean, intentional yield to a queued operation, not a degraded outcome:
       clear turn-failure state and record health success, like a completed
       turn. The keeper resumes its own work on the next cycle. *)
    Log.Keeper.info ~keeper_name:updated_meta.name
      "yielded autonomous Owner child to a queued operation after %d turn(s), checkpoint \
       saved — will resume next cycle"
      turns_used;
    reset_failure_state ()
  | Runtime_agent.Yielded_to_durable_stimulus { turns_used } ->
    Log.Keeper.info ~keeper_name:updated_meta.name
      "yielded autonomous run for a pending durable stimulus after %d turn(s), \
       checkpoint saved — will resume next cycle"
      turns_used;
    reset_failure_state ()
  | Runtime_agent.Yielded_after_repeated_tool_call
      { turns_used; tool_name; repeated_count } ->
    Log.Keeper.warn ~keeper_name:updated_meta.name
      "yielded repeated exact tool loop after %d turn(s): tool=%s count=%d; \
       checkpoint saved — will resume next cycle"
      turns_used
      tool_name
      repeated_count;
    reset_failure_state ()
  | Runtime_agent.Yielded_after_repeated_assistant_text
      { turns_used; repeated_count } ->
    Log.Keeper.warn ~keeper_name:updated_meta.name
      "yielded repeated assistant text after %d turn(s): count=%d; \
       checkpoint saved — will resume next cycle"
      turns_used
      repeated_count;
    reset_failure_state ()
  | Runtime_agent.InputRequired { turns_used; request } ->
    Log.Keeper.info ~keeper_name:updated_meta.name
      "typed input required after %d turn(s), checkpoint saved request_id=%s"
      turns_used
      request.Agent_core.Error.request_id;
    reset_failure_state ()
  | Runtime_agent.Completed -> reset_failure_state ()
;;

module For_testing = struct
  type nonrec terminal_outcome = terminal_outcome =
    | Terminal_done
    | Terminal_checkpoint
    | Terminal_input_required

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
  type nonrec cycle_post_action = cycle_post_action =
    | Assign_task
    | Empty_queue_sleep

  let post_action_of_channel = post_action_of_channel
end

let emit_terminal_fsm ~meta ~keeper_turn_id =
  Keeper_turn_fsm.emit_transition
    ~keeper_name:meta.Keeper_meta_contract.name
    ~turn_id:keeper_turn_id
    ~prev:Keeper_turn_fsm.Streaming
    Keeper_turn_fsm.Completing;
  Keeper_turn_fsm.emit_transition
    ~keeper_name:meta.name
    ~turn_id:keeper_turn_id
    ~prev:Keeper_turn_fsm.Completing
    Keeper_turn_fsm.Done
;;

let handle
      ~config
      ~meta
      ~turn_ctx_cell
      ~observation
      ~latency_ms
      ~degraded_retry_applied
      ~degraded_retry_runtime
      ~fallback_reason
      ~keeper_turn_id
      execution_outcome
  =
  let result = Keeper_execution_outcome.result execution_outcome in
  let channel = Keeper_execution_outcome.metrics_channel execution_outcome in
  let run_projection terminal_effect f =
    KTP.run_best_effort
      ~terminal_effect
      ~on_error:(fun exn ->
        Keeper_turn_helpers.report_keeper_cycle_side_effect_issue
          ~config
          ~keeper_name:meta.name
          ~side_effect:(KTP.effect_label terminal_effect)
          (Printexc.to_string exn))
      f
  in
  let lifecycle =
    apply_lifecycle
      ~config
      ~meta
      result
  in
  let usage_resolution, usage_cursor =
    Keeper_usage_resolution.resolve
      ~cursor:lifecycle.KEC.updated_meta.runtime.usage_cursor
      ~basis:result.usage_basis
      ~observation:
        (if result.usage_reported
         then Some (Keeper_usage_resolution.sample_of_api_usage result.usage)
         else None)
      ~observed_at:(Time_compat.now ())
  in
  let turn_cost = turn_cost usage_resolution in
  let updated_meta =
    KUM.update_metrics_from_result
      lifecycle.KEC.updated_meta
      ~latency_ms
      ~observation
      ~usage_resolution
      ~usage_cursor
      ~is_autonomous_turn:(Keeper_execution_outcome.is_autonomous execution_outcome)
      result
  in
  let updated_meta =
    if Keeper_execution_outcome.is_autonomous execution_outcome
    then acknowledge_pending_messages updated_meta observation
    else updated_meta
  in
  (* RFC-0303 Phase 3: the no-progress loop detector is retired, so the
     metrics-updated meta flows through unchanged (no loop-detection rebind). *)
  let terminal_outcome = terminal_outcome_of_result result in
  append_metrics_snapshot
    ~config
    ~meta
    ~updated_meta
    ~observation
    ~channel
    ~result
    ~latency_ms
    ~usage_resolution
    ~turn_cost
    ~lifecycle
    ~terminal_outcome
    ~execution_outcome;
  let turn_mode = KUM.turn_mode_of_result result in
  let turn_mode_label = KUM.turn_mode_to_string turn_mode in
  let usage_trust =
    KUM.classify_usage_trust
      ~usage_reported:result.Keeper_agent_run.usage_reported
      ~usage:result.usage
  in
  let wall_tokens_per_second =
    match usage_resolution.delta with
    | Some delta when delta.output_tokens >= 0 && latency_ms > 0 ->
      Some (float_of_int delta.output_tokens /. (float_of_int latency_ms /. 1000.0))
    | Some _ | None -> None
  in
  emit_activity_graph
    ~config
    ~updated_meta
    ~result
    ~latency_ms
    ~usage_resolution
    ~turn_cost
    ~usage_trust
    ~turn_mode_label
    ~lifecycle
    ~wall_tokens_per_second
    ~terminal_outcome;
  run_projection KTP.Decision_record (fun () ->
    KUM.append_decision_record
      ~config
      ~meta
      ~turn_ctx_cell
      ~observation
      ~latency_ms
      ~outcome:
        (decision_outcome_to_label
           (decision_outcome_of_terminal_outcome terminal_outcome))
      ~channel
      ~degraded_retry_applied
      ?degraded_retry_runtime
      ?fallback_reason:
        (Option.map Keeper_error_classify.degraded_retry_reason_to_string fallback_reason)
      ~turn_mode
      ~terminal_reason:(terminal_reason_of_outcome result terminal_outcome)
      ~result:(Some result)
      ~usage_resolution:(Some usage_resolution)
      ());
  run_projection KTP.Usage_metrics (fun () ->
    emit_resolved_cost_event
      ~config
      ~meta
      ~keeper_turn_id
      ~result
      ~usage_resolution
      ~usage_trust);
  run_projection KTP.Usage_metrics (fun () ->
    emit_usage_metrics_and_log
      ~updated_meta
      ~result
      ~usage_resolution
      ~latency_ms
      ~usage_trust
      ~turn_mode_label
      ~lifecycle
      ~terminal_outcome);
  run_projection KTP.Usage_metrics (fun () ->
    Keeper_hooks_agent_core.broadcast_resolved_turn_complete
      ~keeper_name:updated_meta.name
      ~turn:keeper_turn_id
      ~tool_calls_made:(Keeper_agent_result.tool_call_count result)
      ~total_turns:updated_meta.runtime.usage.total_turns
      ~usage_resolution);
  (* Every terminal outcome has consumed a keeper turn id. *)
  let updated_meta =
    persist_terminal_turn_meta
      ~config
      ~original_meta:meta
      ~updated_meta
  in
  (* Single source of truth for success-path terminal FSM transitions.
     Completion-contract observations never rewrite a successful runtime turn
     into a failed Keeper lifecycle transition. *)
  run_projection KTP.Terminal_fsm_projection (fun () ->
    emit_terminal_fsm ~meta ~keeper_turn_id);
  (* Turn success is product state, not a best-effort FSM projection. Keep the
     failure counter and health reset outside [run_projection] so an exception
     from either transition emitter cannot leave a completed turn marked as
     failed on the next heartbeat. *)
  reset_turn_failures_for_stop_reason ~config ~updated_meta result;
  Completed updated_meta
;;
