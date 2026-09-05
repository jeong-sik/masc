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
    ~(usage_resolution : Keeper_usage_resolution.t)
    ~(turn_cost : float)
    ~(channel : Keeper_world_observation.keeper_cycle_channel)
    ~(checkpoint_bytes : int option)
    ~(message_count : int)
    () : unit =
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
  let tools_used = Keeper_agent_result.tool_names result in
  let tool_call_count = Keeper_agent_result.tool_call_count result in
  let metrics_store = Keeper_types_support.keeper_metrics_store config meta.name in
  let usage_json =
    match usage_resolution.delta with
    | Some delta ->
      let delta_usage = Keeper_usage_resolution.api_usage_of_sample delta in
      `Assoc
        ([
          ( "usage_scope"
          , `String (Runtime_usage_scope.to_string result.usage_scope) );
          ("input_tokens", `Int delta.input_tokens);
          ("output_tokens", `Int delta.output_tokens);
          ("cache_creation_tokens", `Int delta.cache_creation_input_tokens);
          ("cache_read_tokens", `Int delta.cache_read_input_tokens);
          ("total_tokens",
           `Int (Inference_utils.total_tokens delta_usage));
          ( "resolution_status"
          , `String
              (Keeper_usage_resolution.status_to_string usage_resolution.status) );
        ]
        @ usage_trust_json_fields usage_trust)
    | None ->
      `Assoc
        ([
          ( "usage_scope"
          , `String (Runtime_usage_scope.to_string result.usage_scope) );
          ("input_tokens", `Null);
          ("output_tokens", `Null);
          ("cache_creation_tokens", `Null);
          ("cache_read_tokens", `Null);
          ("total_tokens", `Null);
          ( "resolution_status"
          , `String (Keeper_usage_resolution.status_to_string usage_resolution.status) );
        ]
        @ usage_trust_json_fields usage_trust)
  in
  let cost_json =
    match usage_resolution.delta with
    | Some { cost_usd = Some _; _ } -> `Float turn_cost
    | Some { cost_usd = None; _ } | None -> `Null
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
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string TurnCompleted)
    ~labels:[("keeper", meta.name)]
    ();
  let snapshot =
    `Assoc
      (Keeper_metrics_record.fields Keeper_metrics_record.Turn
      @ [
        ("ts", `String (now_iso ()));
        ("ts_unix", `Float now_ts);
        ("channel", `String (Keeper_world_observation.channel_to_string channel));
        ("name", `String meta.name);
        ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
        ("prompt_fingerprint", `String result.prompt_metrics.fingerprint);
        ("prompt", Keeper_agent_run.prompt_metrics_to_json result.prompt_metrics);
        ("ctx_composition", Keeper_agent_run.ctx_composition_to_json result.ctx_composition);
        ("usage", usage_json);
        ("usage_resolution", Keeper_usage_resolution.to_json usage_resolution);
        ("usage_trust", `String (usage_trust_to_string usage_trust));
        ( "usage_anomaly_reasons",
          `List
            (List.map
               (fun reason -> `String reason)
               (usage_trust_reasons usage_trust)) );
        ("latency_ms", `Int latency_ms);
        ("cost_usd", cost_json);
        ("checkpoint_bytes", Json_util.int_opt_to_json checkpoint_bytes);
        ("message_count", `Int message_count);
        ("turn_mode", `String (turn_mode_to_string turn_mode));
        ("tool_call_count", `Int tool_call_count);
        ("tools_used", `List (List.map (fun tool -> `String tool) tools_used));
        ( "scheduled_autonomous_outcome",
          match scheduled_autonomous_outcome with
          | Some outcome ->
              `String (proactive_cycle_outcome_to_string outcome)
          | None -> `Null );
        ("runtime",
         match result.runtime_observation with
         | Some observation -> redacted_runtime_observation_to_json observation
         | None -> `Null);
        ( "trace_ref",
          match result.trace_ref with
          | Some trace_ref ->
              Agent_core.Raw_trace.run_ref_to_yojson trace_ref
          | None -> `Null );
        ( "run_validation",
          match result.run_validation with
          | Some validation ->
              Agent_core.Raw_trace.run_validation_to_yojson validation
          | None -> `Null );
        ("inference_telemetry",
         match result.inference_telemetry with
         | Some t ->
           Keeper_hooks_agent_core.inference_telemetry_to_runtime_json t
         | None -> `Null);
      ])
  in
  Dated_jsonl.append metrics_store snapshot;
  ()
