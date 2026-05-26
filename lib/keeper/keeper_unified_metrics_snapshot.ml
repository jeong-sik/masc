(** Metrics snapshot append for unified keeper cycle, extracted from
    keeper_unified_metrics.ml. *)

open Keeper_types
open Keeper_exec_context
module Social = Keeper_social_model

include Keeper_unified_metrics_support
include Keeper_unified_metrics_json_support

let append_metrics_snapshot ~(config : Coord.config) ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(result : Keeper_agent_run.run_result) ~(latency_ms : int)
    ~(turn_cost : float)
    ~(turn_generation : int)
    ~(channel : string)
    ~(snapshot_source : string)
    ~(context_ratio : float)
    ~(context_tokens : int)
    ~(context_max : int)
    ~(message_count : int)
    ~(compaction : Keeper_exec_context.compaction_event)
    ~(handoff_json : Yojson.Safe.t option)
    ?provider_timeout_plan_json ?deliberation_execution () : unit =
  let now_ts = Time_compat.now () in
  let _observation = observation in
  let turn_mode = turn_mode_of_result result in
  let usage_trust =
    classify_usage_trust
      ~usage_reported:result.usage_reported
      ~usage:result.usage
      ~context_max
  in
  (* #9953: record context_max_bucket on the neutral runtime lane so
     dashboards can directly count drift without preserving provider/model
     identity at the MASC boundary. *)
  record_context_max_observation
    ~keeper:meta.name
    ~context_max;
  let scheduled_autonomous_outcome =
    if is_scheduled_autonomous_channel channel then
      Some (scheduled_autonomous_outcome_for_result result)
    else None
  in
  let metrics_store = Keeper_types_support.keeper_metrics_store config meta.name in
  let usage_json =
    if result.usage_reported then
      `Assoc
        ([
          ("input_tokens", `Int result.usage.input_tokens);
          ("output_tokens", `Int result.usage.output_tokens);
          ("cache_creation_tokens", `Int result.usage.cache_creation_input_tokens);
          ("cache_read_tokens", `Int result.usage.cache_read_input_tokens);
          ("total_tokens",
           `Int (Keeper_exec_context.total_tokens result.usage));
        ]
        @ usage_trust_json_fields usage_trust)
    else
      `Assoc
        ([
          ("input_tokens", `Null);
          ("output_tokens", `Null);
          ("cache_creation_tokens", `Null);
          ("cache_read_tokens", `Null);
          ("total_tokens", `Null);
        ]
        @ usage_trust_json_fields usage_trust)
  in
  let cost_json =
    if result.usage_reported && usage_trust_is_trusted usage_trust then
      `Float turn_cost
    else `Null
  in
  (* #9943: per-keeper turn-latency bucket counter + WARN if the
     turn crossed the long-turn threshold (default 600s, env-
     overridable).  Emitted once per snapshot write so the
     counter rate matches the JSONL row rate. *)
  record_turn_latency_bucket ~keeper:meta.name ~latency_ms;
  let cascade_profile =
    match result.cascade_observation with
    | Some observation ->
      Cascade_name.to_string
        observation.Cascade_observation.cascade_name
    | None -> (cascade_name_of_meta meta)
  in
  (* #9933: same latency bucket, split by provider/model/cascade.
     This keeps the existing keeper-only counter stable while making
     timeout-budget burn attributable to the redacted runtime lane. *)
  record_turn_latency_by_model_bucket
    ~keeper:meta.name
    ~channel
    ~cascade_profile
    ~latency_ms;
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_turn_completed
    ~labels:[("keeper_name", meta.name)]
    ();
  let snapshot =
    `Assoc
      [
        ("ts", `String (now_iso ()));
        ("ts_unix", `Float now_ts);
        ("channel", `String channel);
        ("name", `String meta.name);
        ("agent_name", `String meta.agent_name);
        ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
        ("generation", `Int turn_generation);
        ("model_used", `Null);
        ("resolved_model_id", `Null);
        ("prompt_fingerprint", `String result.prompt_metrics.fingerprint);
        ("prompt", Keeper_agent_run.prompt_metrics_to_json result.prompt_metrics);
        ( "provider_timeout_plan",
          match provider_timeout_plan_json with
          | Some value -> value
          | None -> `Null );
        ("ctx_composition", Keeper_agent_run.ctx_composition_to_json result.ctx_composition);
        ("usage", usage_json);
        ("usage_trust", `String (usage_trust_to_string usage_trust));
        ( "usage_anomaly_reasons",
          `List
            (List.map
               (fun reason -> `String reason)
               (usage_trust_reasons usage_trust)) );
        ("latency_ms", `Int latency_ms);
        ("cost_usd", cost_json);
        ("context_ratio", `Float context_ratio);
        ("context_tokens", `Int context_tokens);
        ("context_max", `Int context_max);
        ("message_count", `Int message_count);
        ("continuity_state", `Null);
        ("continuity_summary", `String meta.continuity_summary);
        ("compacted", `Bool compaction.applied);
        ("compaction_before_tokens", `Int compaction.before_tokens);
        ("compaction_after_tokens", `Int compaction.after_tokens);
        ("compaction_saved_tokens", `Int compaction.saved_tokens);
        ("compaction_trigger",
          match compaction.trigger with
          | Some trigger -> `String (Compaction_trigger.to_label trigger)
          | None -> `Null);
        ("compaction_trigger_detail",
          match compaction.trigger with
          | Some trigger -> Compaction_trigger.to_detail_json trigger
          | None -> `Null);
        ("turn_mode", `String (turn_mode_to_string turn_mode));
        ( "scheduled_autonomous_outcome",
          match scheduled_autonomous_outcome with
          | Some outcome ->
              `String (proactive_cycle_outcome_to_string outcome)
          | None -> `Null );
        ( "proactive_outcome",
          match scheduled_autonomous_outcome with
          | Some outcome ->
              `String (proactive_cycle_outcome_to_string outcome)
          | None -> `Null );
        ("tool_call_count", `Int result.tool_calls_made);
        ("tools_used", `List (List.map (fun s -> `String s) result.tools_used));
        ( "action_source",
          match deliberation_execution with
          | Some execution ->
              Keeper_deliberation.action_source_of_execution_result execution
              |> Keeper_deliberation.action_source_to_json
          | None -> `Null );
        ( "deliberation_execution",
          match deliberation_execution with
          | Some execution ->
              Keeper_deliberation.execution_result_to_json execution
          | None -> `Null );
        ("cascade",
         match result.cascade_observation with
         | Some observation -> redacted_cascade_observation_to_json observation
         | None -> `Null);
        ("snapshot_source", `String snapshot_source);
        ("memory_check", memory_check_default_json ());
        ("handoff_performed",
         `Bool
           (match handoff_json with
            | Some (`Assoc fields) ->
                Safe_ops.json_bool ~default:false "performed" (`Assoc fields)
            | _ -> false));
        ("handoff",
         match handoff_json with
         | Some value -> value
         | None -> `Assoc [ ("performed", `Bool false) ]);
        ( "trace_ref",
          match result.trace_ref with
          | Some trace_ref ->
              Agent_sdk.Raw_trace.run_ref_to_yojson trace_ref
          | None -> `Null );
        ( "run_validation",
          match result.run_validation with
          | Some validation ->
              Agent_sdk.Raw_trace.run_validation_to_yojson validation
          | None -> `Null );
        ("cdal_proof",
         match result.proof with
         | Some p ->
           `Assoc [
             ("run_id", `String p.Masc_mcp_cdal_runtime.Cdal_proof.run_id);
             ("effective_mode",
              Masc_mcp_cdal_runtime.Execution_mode.to_yojson p.effective_execution_mode);
             ("result_status",
              Masc_mcp_cdal_runtime.Cdal_proof.result_status_to_yojson p.result_status);
             ("violation_count",
              `Int (cdal_violation_ref_count p));
             ("raw_evidence_ref_count",
              `Int (cdal_raw_evidence_ref_count p));
             ("tool_trace_count",
              `Int (List.length p.tool_trace_refs));
             ("mode_source", `String p.mode_decision_source);
           ]
         | None -> `Null);
        ("inference_telemetry",
         match result.inference_telemetry with
         | Some t ->
           Keeper_hooks_oas.inference_telemetry_to_runtime_json t
         | None -> `Null);
      ]
  in
  Dated_jsonl.append metrics_store snapshot;
  (* #9943: a compaction trigger that produced no token reduction
     is invisible in [masc_keeper_compactions_total] (which counts
     trigger fires).  Emit a dedicated counter here so dashboards
     can alert on the noop rate — production audit (2026-04-24)
     showed 956/972 = 98.4% of compaction snapshots were silent
     noops.  Emit only when a trigger fired and before/after match
     at a non-zero token count; the [trigger] label uses the
     human-readable reason already present in the snapshot. *)
  (match compaction.trigger with
   | Some trigger
     when compaction.before_tokens > 0
       && compaction.before_tokens = compaction.after_tokens ->
       (* Closed label set (5 values) keeps the metric cardinality bound; the
          full numerical detail is preserved in the snapshot's
          [compaction_trigger_detail] JSON above. *)
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_compaction_noop
         ~labels:
           [ ("keeper", meta.name)
           ; ("trigger", Compaction_trigger.to_label trigger)
           ]
         ()
   | _ -> ())
