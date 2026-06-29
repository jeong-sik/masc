(** Decision record append for unified keeper cycle, extracted from
    keeper_unified_metrics.ml.

    Largest cluster in this godfile — writes the per-turn decision
    record JSONL (event bus + Otel_metric_store + receipt). *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

include Keeper_unified_metrics_support
include Keeper_unified_metrics_json_support

let append_decision_record
    ~(config : Workspace.config)
    ~(meta : keeper_meta)
    ~(turn_ctx_cell : Keeper_tool_call_log.turn_ctx_cell)
    ~(observation : Keeper_world_observation.world_observation)
    ~(latency_ms : int)
    ~(outcome : string)
    ?(degraded_retry_applied = false)
    ?degraded_retry_runtime
    ?fallback_reason
    ?turn_mode
    ?deliberation_execution
    ?(result : Keeper_agent_run.run_result option = None)
    ?error
    ?terminal_reason
    () : unit =
  let now_ts = Time_compat.now () in
  let trigger_signals = observed_triggers_of_observation ~meta observation in
  let affordances = observed_affordances_of_observation ~meta observation in
  let tool_names =
    match result with
    | Some r -> Keeper_agent_result.tool_names r
    | None -> []
  in
  let response_preview =
    match result with
    | Some r
      when String.trim r.response_text <> ""
           && Keeper_turn_outcome.equal
                (Keeper_turn_outcome.of_result_surface
                   ~response_text:r.response_text r.stop_reason)
                Keeper_turn_outcome.Visible_reply ->
        Some (short_preview r.response_text)
    | _ -> None
  in
  let ( _turn_lane
      , _turn_tool_choice
      , turn_thinking_enabled
      , _turn_thinking_budget
      , _turn_prompt_fingerprint
      , _turn_trace_id
      , _turn_session_id
      , _turn_number
      , turn_id_opt
      , task_id_opt
      , turn_goal_ids_opt
      , _sandbox_profile
      , _network_mode
      , approval_mode ) =
    Keeper_tool_call_log.get_turn_context ~cell:turn_ctx_cell ()
  in
  let turn_id =
    Option.value ~default:meta.runtime.usage.total_turns turn_id_opt
  in
  let task_id =
    match task_id_opt with
    | Some _ as value -> value
    | None -> Keeper_runtime_contract.current_task_id_opt meta
  in
  let goal_ids =
    match turn_goal_ids_opt with
    | Some values -> values
    | None -> meta.active_goal_ids
  in
  let goal_id =
    match goal_ids with
    | value :: _ -> Some value
    | [] -> None
  in
  let runtime_contract =
    Keeper_runtime_contract.runtime_observability_contract_json ~config meta
  in
  let pending_approval_count =
    Keeper_approval_queue.pending_count_for_keeper ~keeper_name:meta.name
  in
  let claim_executed =
    List.exists Keeper_tool_progress.is_claim_tool_name tool_names
  in
  let turn_mode =
    match turn_mode, result with
    | Some mode, _ -> Some mode
    | None, Some r -> Some (turn_mode_of_result r)
    | None, None -> None
  in
  let turn_mode_label = Option.map turn_mode_to_string turn_mode in
  let suffix_seed =
    match response_preview, error with
    | Some preview, _ -> preview
    | None, Some err -> err
    | None, None -> Option.value ~default:outcome turn_mode_label
  in
  let terminal_reason =
    match terminal_reason with
    | Some reason -> reason
    | None -> (
        match outcome, error with
        | "success", _ -> Keeper_turn_terminal.success ()
        | _, Some _ -> Keeper_turn_terminal.of_code ~source:"decision_error" "unknown_error"
        | _ -> Keeper_turn_terminal.of_code "unknown_error")
  in
  let terminal_reason_code = Keeper_turn_terminal.code terminal_reason in
  let json =
    `Assoc
      ([
        ("id", `String (decision_id ~meta ~ts:now_ts ~suffix_seed));
        ("event", `String "turn");
        ("ts", `String (now_iso ()));
        ("ts_unix", `Float now_ts);
        ("audience", `String "internal_human_only");
        ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
        ("generation", `Int meta.runtime.generation);
        ("turn_id", `Int turn_id);
        ("keeper_name", `String meta.name);
        ("agent_name", `String meta.agent_name);
        ("task_id", Json_util.string_opt_to_json task_id);
        ("goal_id", Json_util.string_opt_to_json goal_id);
        ("goal_ids", `List (List.map (fun goal_id -> `String goal_id) goal_ids));
        ("runtime_contract", runtime_contract);
        ("terminal_reason", Keeper_turn_terminal.to_json terminal_reason);
        ("terminal_reason_code", `String terminal_reason_code);
        ( "terminal_reason_severity",
          `String
            (Keeper_turn_terminal.severity_to_string
               terminal_reason.Keeper_turn_terminal.severity) );
        ("terminal_reason_source", `String terminal_reason.source);
        ("provider_context", provider_context_json ~meta result);
        ("tool_surface", tool_surface_json result);
        ("pending_approval_count", `Int pending_approval_count);
        ("approval_mode", Json_util.string_opt_to_json approval_mode);
        ( "channel",
          `String
            (Keeper_world_observation.channel_to_string
               (decision_channel_of_observation observation)) );
        ("outcome", `String outcome);
        ("degraded_retry_applied", `Bool degraded_retry_applied);
        ( "degraded_retry_runtime",
          Json_util.string_opt_to_json degraded_retry_runtime );
        ("fallback_reason", Json_util.string_opt_to_json fallback_reason);
        ("turn_mode", Json_util.string_opt_to_json turn_mode_label);
        ("latency_ms", `Int latency_ms);
        ("duration_ms", `Int latency_ms);
        ("trigger_signals", `List (List.map (fun s -> `String s) trigger_signals));
        ("observed_affordances", `List (List.map (fun s -> `String s) affordances));
        ( "observation",
          `Assoc
            [
              ("pending_mentions", `Int (List.length observation.pending_mentions));
              ("pending_board_events", `Int (List.length observation.pending_board_events));
              ("pending_scope_messages", `Int (List.length observation.pending_scope_messages));
              ("active_goals", `Int (List.length observation.active_goals));
              ("idle_seconds", `Int observation.idle_seconds);
              ("context_ratio", `Float (Lazy.force observation.context_ratio));
              ("unclaimed_task_count", `Int observation.unclaimed_task_count);
              ("claimable_task_count", `Int observation.claimable_task_count);
              ( "provider_capacity_blocked_task_count",
                `Int observation.provider_capacity_blocked_task_count );
              ( "claim_blocked_task_count",
                `Int
                  (max 0
                     (observation.unclaimed_task_count
                      - observation.claimable_task_count)) );
              ("failed_task_count", `Int observation.failed_task_count);
              ("pending_verification_count", `Int observation.pending_verification_count);
              ( "scheduled_automation_active_count",
                `Int observation.scheduled_automation.active_count );
              ( "scheduled_automation_due_ready_count",
                `Int observation.scheduled_automation.due_ready_count );
              ( "scheduled_automation_blocked_approval_count",
                `Int observation.scheduled_automation.blocked_approval_count );
              ("running_keeper_fiber_count", `Int observation.running_keeper_fiber_count);
            ] );
        ("claim_absolute_available", `Bool (observation.unclaimed_task_count > 0));
        ("claim_matched_available", `Bool (observation.claimable_task_count > 0));
        ("claim_was_available", `Bool (observation.claimable_task_count > 0));
        ("claim_executed", `Bool claim_executed);
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
          ~goal:meta.goal deliberation_execution;
        ( "response_preview", Json_util.string_opt_to_json response_preview );
        ( "response_preview_2000",
          match result with
          | Some r when String.trim r.response_text <> "" ->
              `String (short_preview ~max_len:2000 r.response_text)
          | _ -> `Null );
        ( "response_requests_confirmation",
          `Bool
            (match result with
             | Some r -> response_requests_confirmation r.response_text
             | None -> false) );
        ( "error", Json_util.string_opt_to_json error );
        ( "trace_ref",
          match result with
          | Some { trace_ref = Some trace_ref; _ } ->
              Agent_sdk.Raw_trace.run_ref_to_yojson trace_ref
          | _ -> `Null );
        ( "run_validation",
          match result with
          | Some { run_validation = Some validation; _ } ->
              Agent_sdk.Raw_trace.run_validation_to_yojson validation
          | _ -> `Null );
        ( "telemetry",
          match result with
          | Some r ->
              let telemetry_reported = telemetry_reported_of_result r in
              let coverage_reason = coverage_reason_of_result r in
              let coverage_stage = coverage_stage_of_result r in
              let usage_trust =
                classify_usage_trust
                  ~usage_reported:r.usage_reported
                  ~usage:r.usage
                  ~context_max:0
              in
              let thinking_enabled_field =
                match turn_thinking_enabled with
                | Some b -> [("thinking_enabled", `Bool b)]
                | None -> []
              in
              let runtime_fields =
                match r.runtime_observation with
                | Some co ->
                    let runtime_id =
                      co.runtime_id
                    in
                    let streaming_fields =
                      [
                        ("streaming_ttfrc_ms", Json_util.float_opt_to_json co.streaming_ttfrc_ms);
                        ("streaming_inter_chunk_count", `Int co.streaming_inter_chunk_count);
                        ("streaming_inter_chunk_avg_ms", Json_util.float_opt_to_json co.streaming_inter_chunk_avg_ms);
                      ]
                    in
                    [
                      ("runtime_id", `String runtime_id);
                      ("strategy", Json_util.string_opt_to_json co.strategy);
                      ("primary_model", `Null);
                      ("selected_model", `Null);
                      ("fallback_applied", `Bool co.fallback_applied);
                      ("fallback_hops", match co.fallback_hops with Some n -> `Int n | None -> `Int 0);
                      ("candidate_models", `List []);
                    ] @ streaming_fields
                | None -> []
              in
              let tool_surface_fields =
                [
                  ( "turn_lane"
                  , Keeper_agent_tool_surface.turn_lane_to_yojson
                      r.tool_surface.turn_lane );
                  ("config_root", `String r.tool_surface.config_root);
                  ( "runtime_config_path",
                    Json_util.string_opt_to_json r.tool_surface.runtime_config_path );
                ]
              in
                let stop_reason_str =
                  match r.stop_reason with
                  | Runtime_agent.Completed -> "completed"
                  | Runtime_agent.TurnBudgetExhausted { turns_used; limit } ->
                      Keeper_turn_disposition.(
                        to_wire
                          (Turn_budget_exhausted
                             { dimension = `Turns
                             ; used = turns_used
                             ; limit
                             ; source = `Oas_sdk
                             }))
                  | Runtime_agent.MutationBoundaryReached { turns_used; tool_name } ->
                      (match tool_name with
                       | Some tool ->
                           Printf.sprintf "mutation_boundary(%d:%s)" turns_used tool
                       | None ->
                           Printf.sprintf "mutation_boundary(%d)" turns_used)
                in
              let inference_fields =
                match r.inference_telemetry with
                | Some t ->
                    let timings_fields =
                      match t.timings with
                      | Some ti ->
                          (* hw_decode_tokens_per_second: unambiguous alias of
                             provider_tokens_per_second. Both read ti.predicted_per_second
                             (eval_count / eval_duration from Ollama), which is the true
                             hardware decode rate — distinct from the wall-clock
                             tokens_per_second (output_tokens / latency_ms) below. Dashboards
                             should prefer hw_decode_* name; legacy name kept for backward compat. *)
                          [
                            ("prompt_ms", Json_util.float_opt_to_json ti.prompt_ms);
                            ("predicted_ms", Json_util.float_opt_to_json ti.predicted_ms);
                            ("provider_tokens_per_second", Json_util.float_opt_to_json ti.predicted_per_second);
                            ("hw_decode_tokens_per_second", Json_util.float_opt_to_json ti.predicted_per_second);
                            ("prompt_per_second", Json_util.float_opt_to_json ti.prompt_per_second);
                            ("cache_n", Json_util.int_opt_to_json ti.cache_n);
                          ]
                      | None -> []
                    in
                    [
                      ("system_fingerprint", Json_util.string_opt_to_json t.system_fingerprint);
                      ("reasoning_tokens", Json_util.int_opt_to_json t.reasoning_tokens);
                      ("request_latency_ms", Json_util.int_opt_to_json t.request_latency_ms);
                    ] @ timings_fields
                | None -> []
              in
              let usage_fields =
                if r.usage_reported then
                  [
                    ("input_tokens", `Int r.usage.input_tokens);
                    ("output_tokens", `Int r.usage.output_tokens);
                    ("cache_creation_tokens", `Int r.usage.cache_creation_input_tokens);
                    ("cache_read_tokens", `Int r.usage.cache_read_input_tokens);
                    ("cost_usd", Json_util.float_opt_to_json r.usage.cost_usd);
                    ( "tokens_per_second",
                      if usage_trust_is_trusted usage_trust && latency_ms > 0 then
                        `Float
                          (float_of_int r.usage.output_tokens
                           /. (float_of_int latency_ms /. 1000.0))
                      else `Null );
                  ]
                  @ usage_trust_json_fields usage_trust
                else
                  [
                    ("input_tokens", `Null);
                    ("output_tokens", `Null);
                    ("cache_creation_tokens", `Null);
                    ("cache_read_tokens", `Null);
                    ("cost_usd", `Null);
                    ("tokens_per_second", `Null);
                  ]
                  @ usage_trust_json_fields usage_trust
              in
              `Assoc ([
                ("model_used", `Null);
                ("resolved_model_id", `Null);
                ("outcome", `String "success");
                ("turn_count", `Int r.turn_count);
                ("stop_reason", `String stop_reason_str);
                ("usage_reported", `Bool r.usage_reported);
                ("telemetry_reported", `Bool telemetry_reported);
                ( "coverage_stage", Json_util.string_opt_to_json coverage_stage );
                ( "coverage_reason", Json_util.string_opt_to_json coverage_reason );
              ] @ usage_fields @ thinking_enabled_field @ inference_fields @ runtime_fields @ tool_surface_fields)
          | None ->
              (* Partial telemetry for turns without a run_result: record
                 what we know without collapsing skipped/cancelled/partial
                 outcomes into telemetry.outcome=error. *)
              let error_category =
                error_category_of_no_result_outcome ~outcome ~error
              in
              `Assoc [
                ("runtime_id", `String (runtime_id_of_meta meta));
                ("candidate_models", `List []);
                ( "error_category", Json_util.string_opt_to_json error_category );
                ("outcome", `String outcome);
                ("usage_reported", `Bool false);
                ("telemetry_reported", `Bool false);
                ( "coverage_stage",
                  `String (coverage_stage_of_no_result_outcome outcome) );
                ( "coverage_reason",
                  `String (coverage_reason_of_no_result_outcome outcome) );
              ] );
      ])
  in
  try
    Keeper_types_support.append_jsonl_line
      (Keeper_types_support.keeper_decision_log_path config meta.name)
      json
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string DecisionAuditFlushFailures)
        ~labels:[("keeper", meta.name)]
        ();
      Log.Keeper.warn "append decision record failed for %s: %s"
        meta.name (Printexc.to_string exn)

(** Observe tool call history from run_result to update keeper metrics.
    No action_taken type — we observe what the agent did, not classify it. *)
