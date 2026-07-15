(** Metrics snapshot append for unified keeper cycle, extracted from
    keeper_unified_metrics.ml. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

include Keeper_unified_metrics_support
include Keeper_unified_metrics_json_support

let append_metrics_snapshot ~(config : Workspace.config) ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(result : Keeper_agent_run.run_result) ~(latency_ms : int)
    ~(turn_cost : float)
    ~(turn_generation : int)
    ~(channel : Keeper_world_observation.keeper_cycle_channel)
    ~(snapshot_source : string)
    ~(checkpoint_bytes : int)
    ~(message_count : int)
    ~(compaction : Keeper_context_runtime.compaction_event)
    ~(handoff_json : Yojson.Safe.t option)
    ?(count_completed_turn = true)
    ?deliberation_execution () : unit =
  let now_ts = Time_compat.now () in
  let _observation = observation in
  let turn_mode = turn_mode_of_result result in
  let usage_trust =
    classify_usage_trust
      ~usage_reported:result.usage_reported
      ~usage:result.usage
  in
  let scheduled_autonomous_outcome =
    if Keeper_world_observation.is_autonomous channel then
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
           `Int (Keeper_context_runtime.total_tokens result.usage));
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
    if result.usage_reported then `Float turn_cost else `Null
  in
  (* #9943: per-keeper turn-latency bucket counter + WARN if the
     turn crossed the long-turn threshold (default 600s, env-
     overridable).  Emitted once per snapshot write so the
     counter rate matches the JSONL row rate. *)
  record_turn_latency_bucket ~keeper:meta.name ~latency_ms;
  let runtime_profile =
    match result.runtime_observation with
    | Some observation ->
        observation.Runtime_observation.runtime_id
    | None -> (runtime_id_of_meta meta)
  in
  (* #9933: same latency bucket, split by provider/model/runtime.
     This keeps the existing keeper-only counter stable while making
     long-running turns attributable to the redacted runtime lane. *)
  record_turn_latency_by_model_bucket
    ~keeper:meta.name
    ~channel:(Keeper_world_observation.channel_to_string channel)
    ~runtime_profile
    ~latency_ms;
  if count_completed_turn
  then
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string TurnCompleted)
      ~labels:[("keeper", meta.name)]
      ();
  let snapshot =
    `Assoc
      [
        ("ts", `String (now_iso ()));
        ("ts_unix", `Float now_ts);
        ("channel", `String (Keeper_world_observation.channel_to_string channel));
        ("name", `String meta.name);
        ("agent_name", `String meta.agent_name);
        ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
        ("generation", `Int turn_generation);
        ("model_used", `Null);
        ("resolved_model_id", `Null);
        ("prompt_fingerprint", `String result.prompt_metrics.fingerprint);
        ("prompt", Keeper_agent_run.prompt_metrics_to_json result.prompt_metrics);
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
        ("checkpoint_bytes", `Int checkpoint_bytes);
        ("message_count", `Int message_count);
        ("continuity_state", `Null);
        ("compacted", `Bool compaction.applied);
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
        Keeper_delegation_request.delegation_request_field ~requester:meta.name
          deliberation_execution;
        ("runtime",
         match result.runtime_observation with
         | Some observation -> redacted_runtime_observation_to_json observation
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
        ("inference_telemetry",
         match result.inference_telemetry with
         | Some t ->
           Keeper_hooks_oas.inference_telemetry_to_runtime_json t
         | None -> `Null);
      ]
  in
  Dated_jsonl.append metrics_store snapshot;
  ()
