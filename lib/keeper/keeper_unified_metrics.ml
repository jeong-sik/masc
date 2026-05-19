(** Keeper_unified_metrics — Observation helpers, decision records, and
    metrics update for the unified keeper cycle.

    Extracted from keeper_unified_turn.ml to reduce godfile size.
    All functions here are pure or write-only (JSONL/SSE); no keeper
    lifecycle state is owned by this module.

    @since 0.120.0 *)

open Keeper_types
open Keeper_exec_context
module Social = Keeper_social_model

include Keeper_unified_metrics_support
include Keeper_unified_metrics_json_support


let append_decision_record
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(latency_ms : int)
    ?(semaphore_wait_ms : int = 0)
    ~(outcome : string)
    ?(degraded_retry_applied = false)
    ?degraded_retry_cascade
    ?fallback_reason
    ?turn_mode
    ?social_state
    ?deliberation_execution
    ?(result : Keeper_agent_run.run_result option = None)
    ?error
    ?terminal_reason
    () : unit =
  let now_ts = Time_compat.now () in
  let trigger_signals = observed_triggers_of_observation ~meta observation in
  let affordances = observed_affordances_of_observation ~meta observation in
  let tools_used =
    match result with
    | Some r -> r.tools_used
    | None -> []
  in
  let response_preview =
    match result with
    | Some r when String.trim r.response_text <> "" ->
        Some (short_preview r.response_text)
    | _ -> None
  in
  let tool_call_count =
    match result with
    | Some r -> r.tool_calls_made
    | None -> 0
  in
  let tool_calls =
    match result with
    | Some r -> r.tool_calls
    | None -> []
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
    Keeper_tool_call_log.get_turn_context ~keeper_name:meta.name ()
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
    Keeper_runtime_contract.runtime_contract_json ~config meta
  in
  let pending_approval_count =
    Keeper_approval_queue.pending_count_for_keeper ~keeper_name:meta.name
  in
  let claim_executed =
    List.exists Keeper_tool_disclosure.is_claim_tool_name tools_used
  in
  let social_fields =
    match social_state with
    | None -> []
    | Some state ->
        let option_field key = function
          | Some value -> (key, `String value)
          | None -> (key, `Null)
        in
        [
          ("social_model", `String state.Social.social_model);
          ("belief_summary", `String state.belief_summary);
          option_field "active_desire" state.active_desire;
          option_field "current_intention" state.current_intention;
          option_field "blocker" state.blocker;
          option_field "need" state.need;
          ("speech_act", `String (Social.speech_act_to_string state.speech_act));
          ( "delivery_surface",
            `String
              (Social.delivery_surface_to_string state.delivery_surface) );
        ]
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
        | _, Some err -> Keeper_turn_terminal.of_legacy_error_text err
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
        ("tool_contract", tool_contract_json ~tool_call_count ~tools_used result);
        ("pending_approval_count", `Int pending_approval_count);
        ("approval_mode", Json_util.string_opt_to_json approval_mode);
        ("channel", `String (decision_channel_of_observation observation));
        ("outcome", `String outcome);
        ("degraded_retry_applied", `Bool degraded_retry_applied);
        ( "degraded_retry_cascade",
          Json_util.string_opt_to_json degraded_retry_cascade );
        ("fallback_reason", Json_util.string_opt_to_json fallback_reason);
        ("turn_mode", Json_util.string_opt_to_json turn_mode_label);
        ("latency_ms", `Int latency_ms);
        ("duration_ms", `Int latency_ms);
        ("semaphore_wait_ms", `Int semaphore_wait_ms);
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
              ("context_ratio", `Float observation.context_ratio);
              ("unclaimed_task_count", `Int observation.unclaimed_task_count);
              ("claimable_task_count", `Int observation.claimable_task_count);
              ( "claim_blocked_task_count",
                `Int
                  (max 0
                     (observation.unclaimed_task_count
                      - observation.claimable_task_count)) );
              ("failed_task_count", `Int observation.failed_task_count);
              ("pending_verification_count", `Int observation.pending_verification_count);
              ("active_agent_count", `Int observation.active_agent_count);
              ("worktree_change_detected", `Bool (Option.is_some observation.worktree_change_summary));
            ] );
        ("tool_call_count", `Int tool_call_count);
        ("tools_used", `List (List.map (fun s -> `String s) tools_used));
        ("tool_calls", `List (List.map tool_call_detail_to_json tool_calls));
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
        ( "response_preview",
          match response_preview with
          | Some preview -> `String preview
          | None -> `Null );
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
        ( "error",
          match error with
          | Some reason -> `String reason
          | None -> `Null );
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
        ( "cdal_proof",
          match result with
          | Some { proof = Some p; _ } ->
              `Assoc
                [
                  ("run_id", `String p.Masc_mcp_cdal_runtime.Cdal_proof.run_id);
                  ( "result_status",
                    Masc_mcp_cdal_runtime.Cdal_proof.result_status_to_yojson p.result_status );
                  ("tool_trace_count", `Int (List.length p.tool_trace_refs));
                ]
          | _ -> `Null );
        ( "telemetry",
          match result with
          | Some r ->
              let surface_model_used = Keeper_agent_run.surface_model_used r in
              let resolved_model_id =
                Keeper_agent_run.surface_resolved_model_id r
              in
              let telemetry_reported = telemetry_reported_of_result r in
              let coverage_reason = coverage_reason_of_result r in
              let coverage_stage = coverage_stage_of_result r in
              let usage_trust =
                classify_usage_trust
                  ~usage_reported:r.usage_reported
                  ~usage:r.usage
                  ~model_used:surface_model_used
                  ~resolved_model_id
                  ~context_max:0
              in
              let thinking_enabled_field =
                match turn_thinking_enabled with
                | Some b -> [("thinking_enabled", `Bool b)]
                | None -> []
              in
              let cascade_fields =
                match r.cascade_observation with
                | Some co ->
                    let cascade_name =
                      Keeper_cascade_profile.runtime_name_to_string
                        co.cascade_name
                    in
                    [
                      ("cascade_name", `String cascade_name);
                      ("strategy", Json_util.string_opt_to_json co.strategy);
                      ("primary_model", `Null);
                      ("selected_model", `Null);
                      ("fallback_applied", `Bool co.fallback_applied);
                      ("fallback_hops", match co.fallback_hops with Some n -> `Int n | None -> `Int 0);
                      ("candidate_models", `List []);
                    ]
                | None -> []
              in
              let tool_surface_fields =
                [
                  ( "turn_lane"
                  , Keeper_agent_tool_surface.turn_lane_to_yojson
                      r.tool_surface.turn_lane );
                  ( "tool_surface_class"
                  , Keeper_agent_tool_surface.tool_surface_class_to_yojson
                      r.tool_surface.tool_surface_class );
                  ("tool_requirement", Keeper_agent_tool_surface.tool_requirement_to_yojson r.tool_surface.tool_requirement);
                  ("visible_tool_count", `Int r.tool_surface.visible_tool_count);
                  ("tool_gate_enabled", `Bool r.tool_surface.tool_gate_enabled);
                  ( "tool_surface_fallback_used",
                    `Bool r.tool_surface.tool_surface_fallback_used );
                  ( "required_tool_names",
                    `List
                      (List.map
                         (fun name -> `String name)
                         r.tool_surface.required_tool_names) );
                  ( "missing_required_tool_names",
                    `List
                      (List.map
                         (fun name -> `String name)
                         r.tool_surface.missing_required_tool_names) );
                  ("config_root", `String r.tool_surface.config_root);
                  ( "cascade_config_path",
                    match r.tool_surface.cascade_config_path with
                    | Some path -> `String path
                    | None -> `Null );
                  ("gemini_mcp_disabled", `Bool r.tool_surface.gemini_mcp_disabled);
                  ( "approval_mode_effective",
                    match r.tool_surface.approval_mode_effective with
                    | Some mode -> `String mode
                    | None -> `Null );
                  ("approval_mode_derived", `Bool r.tool_surface.approval_mode_derived);
                ]
              in
                let stop_reason_str =
                  match r.stop_reason with
                  | Cascade_runner.Completed -> "completed"
                  | Cascade_runner.TurnBudgetExhausted { turns_used; limit } ->
                      Printf.sprintf "turn_budget_exhausted(%d/%d)" turns_used limit
                  | Cascade_runner.MutationBoundaryReached { turns_used; tool_name } ->
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
                            ("prompt_ms", match ti.prompt_ms with Some v -> `Float v | None -> `Null);
                            ("predicted_ms", match ti.predicted_ms with Some v -> `Float v | None -> `Null);
                            ("provider_tokens_per_second", match ti.predicted_per_second with Some v -> `Float v | None -> `Null);
                            ("hw_decode_tokens_per_second", match ti.predicted_per_second with Some v -> `Float v | None -> `Null);
                            ("prompt_per_second", match ti.prompt_per_second with Some v -> `Float v | None -> `Null);
                            ("cache_n", match ti.cache_n with Some v -> `Int v | None -> `Null);
                          ]
                      | None -> []
                    in
                    [
                      ("system_fingerprint", match t.system_fingerprint with Some s -> `String s | None -> `Null);
                      ("reasoning_tokens", match t.reasoning_tokens with Some n -> `Int n | None -> `Null);
                      ("request_latency_ms", match t.request_latency_ms with Some n -> `Int n | None -> `Null);
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
                    ("cost_usd", match r.usage.cost_usd with Some c -> `Float c | None -> `Null);
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
                ( "coverage_stage",
                  match coverage_stage with
                  | Some stage -> `String stage
                  | None -> `Null );
                ( "coverage_reason",
                  match coverage_reason with
                  | Some reason -> `String reason
                  | None -> `Null );
              ] @ usage_fields @ thinking_enabled_field @ inference_fields @ cascade_fields @ tool_surface_fields)
          | None ->
              (* Partial telemetry for turns without a run_result: record
                 what we know without collapsing skipped/cancelled/partial
                 outcomes into telemetry.outcome=error. *)
              let error_category =
                error_category_of_no_result_outcome ~outcome ~error
              in
              `Assoc [
                ("cascade_name", `String (cascade_name_of_meta meta));
                ("candidate_models", `List []);
                ( "error_category",
                  match error_category with
                  | Some category -> `String category
                  | None -> `Null );
                ("outcome", `String outcome);
                ("usage_reported", `Bool false);
                ("telemetry_reported", `Bool false);
                ( "coverage_stage",
                  `String (coverage_stage_of_no_result_outcome outcome) );
                ( "coverage_reason",
                  `String (coverage_reason_of_no_result_outcome outcome) );
              ] );
      ]
      @ social_fields)
  in
  try append_jsonl_line (keeper_decision_log_path config meta.name) json
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_decision_audit_flush_failures
        ~labels:[("keeper", meta.name)]
        ();
      Log.Keeper.warn "append decision record failed for %s: %s"
        meta.name (Printexc.to_string exn)

(** Observe tool call history from run_result to update keeper metrics.
    No action_taken type — we observe what the agent did, not classify it. *)
let update_metrics_from_result (meta : keeper_meta) ~(latency_ms : int)
    ~(observation : Keeper_world_observation.world_observation)
    ?(is_autonomous_turn = true)
    ?(update_proactive_rt = true)
    ?social_state
    ?social_transition_reason
    ?(context_max = 0)
    (result : Keeper_agent_run.run_result) : keeper_meta =
  let now_ts = Time_compat.now () in
  let surface_model_used = Keeper_agent_run.surface_model_used result in
  let resolved_model_id = Keeper_agent_run.surface_resolved_model_id result in
  let usage_trust =
    classify_usage_trust
      ~usage_reported:result.usage_reported
      ~usage:result.usage
      ~model_used:surface_model_used
      ~resolved_model_id
      ~context_max
  in
  (* #9959: surface classification into Prometheus exactly once per
     turn. Other [classify_usage_trust] call sites serialize the
     trust into JSONL but do not bump the counter. *)
  record_usage_trust ~keeper_name:meta.name ~trust:usage_trust;
  record_keeper_idle_seconds
    ~keeper_name:meta.name
    ~idle_seconds:observation.idle_seconds;
  let usage_trusted = usage_trust_is_trusted usage_trust in
  let trusted_input_tokens =
    if usage_trusted then result.usage.input_tokens else 0
  in
  let trusted_output_tokens =
    if usage_trusted then result.usage.output_tokens else 0
  in
  let trusted_total_tokens =
    if usage_trusted then Keeper_exec_context.total_tokens result.usage else 0
  in
  let turn_cost =
    estimate_trusted_usage_cost_usd
      ~usage_trusted
      ~model:surface_model_used
      result.usage
  in
  let substantive_tool_call_count =
    result.tools_used
    |> List.filter (fun name -> not (is_observation_only_tool_name name))
    |> List.length
  in
  let has_substantive_tools = has_substantive_tool_calls result.tools_used in
  let has_text = String.trim result.response_text <> "" in
  let validated_evidence = visible_run_validation result in
  let has_validated_evidence = Option.is_some validated_evidence in
  let visible_tool_signal_present =
    has_substantive_tools || has_validated_evidence
  in
  let is_scheduled_autonomous_cycle =
    is_scheduled_autonomous_cycle_of_observation observation
  in
  let is_board_reactive = observation.pending_board_events <> [] in
  let is_mention_reactive = observation.pending_mentions <> [] in
  let has_meaningful_work =
    has_text || has_substantive_tools || has_validated_evidence
  in
  let rt = meta.runtime in
  let social_state : Social.social_state =
    Option.value social_state
      ~default:
        Social.
          {
            social_model = meta.social_model;
            belief_summary = "not_recorded";
            active_desire = None;
            current_intention = None;
            blocker = None;
            need = None;
            speech_act = Social.Inform;
            delivery_surface = Social.Visible_reply;
          }
  in
  (* #10474: proactive outcome counter for successful cycles. *)
  if update_proactive_rt && is_scheduled_autonomous_cycle then begin
    let outcome =
      if has_substantive_tools then "tool_called"
      else if is_noop_cycle ~has_text ~tools_used:result.tools_used
      then "noop"
      else "tool_called"
    in
    Prometheus.inc_counter Keeper_metrics.metric_keeper_proactive_outcome
      ~labels:[ ("keeper", meta.name); ("outcome", outcome) ]
      ()
  end;
  let updated_meta = {
    meta with
    updated_at = now_iso ();
    runtime = { rt with
      usage = {
        total_turns = rt.usage.total_turns + 1;
        total_input_tokens = rt.usage.total_input_tokens + trusted_input_tokens;
        total_output_tokens =
          rt.usage.total_output_tokens + trusted_output_tokens;
        total_tokens =
          rt.usage.total_tokens + trusted_total_tokens;
        total_cost_usd = rt.usage.total_cost_usd +. turn_cost;
        last_turn_ts = now_ts;
        last_model_used = "";
        last_input_tokens = trusted_input_tokens;
        last_output_tokens = trusted_output_tokens;
        last_total_tokens = trusted_total_tokens;
        last_latency_ms = latency_ms;
      };
      (* Deterministic scheduled autonomous cycle accounting is separated from
         nondeterministic model output visibility. *)
      proactive_rt = {
        count_total =
          rt.proactive_rt.count_total
          + (if update_proactive_rt && is_scheduled_autonomous_cycle then 1 else 0);
        last_ts =
          (if update_proactive_rt
              && (is_scheduled_autonomous_cycle
                  || ((is_board_reactive || is_mention_reactive)
                      && has_meaningful_work))
           then now_ts
           else rt.proactive_rt.last_ts);
        visible_count_total =
          rt.proactive_rt.visible_count_total
          + (if update_proactive_rt
               && is_scheduled_autonomous_cycle
               && (has_text || visible_tool_signal_present)
             then 1
             else 0);
        last_visible_ts =
          (if update_proactive_rt
              && is_scheduled_autonomous_cycle
              && (has_text || visible_tool_signal_present)
           then now_ts
           else rt.proactive_rt.last_visible_ts);
        last_outcome =
          (if update_proactive_rt && is_scheduled_autonomous_cycle then
             scheduled_autonomous_outcome_of_result ~has_text
               ~has_tool_calls:visible_tool_signal_present
           else rt.proactive_rt.last_outcome);
        last_reason =
          (if not update_proactive_rt || not is_scheduled_autonomous_cycle
           then rt.proactive_rt.last_reason
           else if has_substantive_tools then
             Printf.sprintf "unified:tools=[%s]"
               (String.concat "," result.tools_used)
           else if has_validated_evidence then
             (match validated_evidence with
              | Some v ->
                Printf.sprintf "unified:validated_evidence(ok=%b,file_write=%b,evidence=%d)"
                  v.ok v.has_file_write (List.length v.evidence)
              | None -> "unified:validated_evidence(unreachable)")
           else if not has_text then
             "unified:"
             ^ scheduled_autonomous_cycle_outcome_to_string Proactive_silent
            else if has_text then "unified:text_response"
            else rt.proactive_rt.last_reason);
        last_preview =
          (if not update_proactive_rt || not is_scheduled_autonomous_cycle
           then rt.proactive_rt.last_preview
           else if has_text then short_preview result.response_text
           else if has_substantive_tools then
             Printf.sprintf "(tools: %s)" (String.concat ", " result.tools_used)
           else
             (match validated_evidence with
              | Some v -> validated_evidence_preview v
              | None -> rt.proactive_rt.last_preview)
          );
        (* Work discovery timestamp only advances when the keeper
           actually used tools in response to the nudge. This is
           intentional: the "Work Discovery Due" prompt block keeps
           being injected until the keeper takes visible action,
           preventing silent cycles from consuming the scan interval. *)
        last_work_discovery_ts =
          (if observation.work_discovery_due && has_substantive_tools then
             now_ts
           else rt.proactive_rt.last_work_discovery_ts);
        work_discovery_count =
          rt.proactive_rt.work_discovery_count
          + (if observation.work_discovery_due && has_substantive_tools then 1
             else 0);
        consecutive_noop_count =
          (if update_proactive_rt && is_scheduled_autonomous_cycle then
             if is_noop_cycle ~has_text ~tools_used:result.tools_used
             then rt.proactive_rt.consecutive_noop_count + 1
             else 0
           else rt.proactive_rt.consecutive_noop_count);
      };
      (* Autonomous action tracking from tool calls *)
      autonomous_action_count =
        rt.autonomous_action_count
        + (if is_autonomous_turn then substantive_tool_call_count else 0);
      autonomous_turn_count =
        rt.autonomous_turn_count + (if is_autonomous_turn then 1 else 0);
      autonomous_text_turn_count =
        rt.autonomous_text_turn_count
        + (if is_autonomous_turn && has_text && not has_substantive_tools then 1 else 0);
      autonomous_tool_turn_count =
        rt.autonomous_tool_turn_count
        + (if is_autonomous_turn && has_substantive_tools then 1 else 0);
      board_reactive_turn_count =
        rt.board_reactive_turn_count + (if is_board_reactive then 1 else 0);
      mention_reactive_turn_count =
        rt.mention_reactive_turn_count + (if is_mention_reactive then 1 else 0);
      noop_turn_count =
        rt.noop_turn_count
        + (if is_autonomous_turn && not has_text && not has_substantive_tools
              && not has_validated_evidence then 1 else 0);
      (* This timestamp stays scoped to substantive tool actions.
         Validated evidence affects proactive visibility, but it does not
         redefine the autonomous action counter semantics. *)
      last_autonomous_action_at =
        (if is_autonomous_turn && has_substantive_tools
         then now_iso ()
         else rt.last_autonomous_action_at);
      last_speech_act = Social.speech_act_to_string social_state.speech_act;
      last_social_transition_reason =
        (match social_transition_reason with
         | Some reason -> String.trim reason
         | None -> rt.last_social_transition_reason);
      last_active_desire =
        Option.value ~default:"" social_state.active_desire;
      last_current_intention =
        Option.value ~default:"" social_state.current_intention;
      (* A successful turn means the keeper is not blocked.
         Clear unconditionally so stale error strings from previous
         failures do not persist in the runtime JSON and mislead the
         dashboard into showing BLOCKED status.  The social model's
         blocker field is a protocol-level signal; runtime last_blocker
         tracks whether the keeper can make progress. *)
      last_blocker = None;
      last_need = Option.value ~default:"" social_state.need;
    };
  } in
  record_keeper_total_cost_usd
    ~keeper_name:updated_meta.name
    ~total_cost_usd:updated_meta.runtime.usage.total_cost_usd;
  updated_meta

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
    ?timeout_budget_json ?deliberation_execution () : unit =
  let now_ts = Time_compat.now () in
  let _observation = observation in
  let turn_mode = turn_mode_of_result result in
  let surface_model_used = Keeper_agent_run.surface_model_used result in
  let resolved_model_id = Keeper_agent_run.surface_resolved_model_id result in
  let usage_trust =
    classify_usage_trust
      ~usage_reported:result.usage_reported
      ~usage:result.usage
      ~model_used:surface_model_used
      ~resolved_model_id
      ~context_max
  in
  (* #9953: record the (keeper, model_used, resolved_model_id,
     context_max_bucket) tuple so dashboards can directly count
     drift.  A model whose label takes >1 bucket on a single
     deployment indicates the resolution path produced
     different ceilings on different turns. *)
  record_context_max_observation
    ~keeper:meta.name
    ~model_used:surface_model_used
    ~resolved_model_id
    ~context_max;
  let scheduled_autonomous_outcome =
    if is_scheduled_autonomous_channel channel then
      Some (scheduled_autonomous_outcome_for_result result)
    else None
  in
  let metrics_store = keeper_metrics_store config meta.name in
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
      Keeper_cascade_profile.runtime_name_to_string
        observation.Cascade_legacy_runner.cascade_name
    | None -> (cascade_name_of_meta meta)
  in
  (* #9933: same latency bucket, split by provider/model/cascade.
     This keeps the existing keeper-only counter stable while making
     timeout-budget burn attributable to a concrete model surface. *)
  record_turn_latency_by_model_bucket
    ~keeper:meta.name
    ~channel
    ~model_used:surface_model_used
    ~resolved_model_id
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
        ( "timeout_budget",
          match timeout_budget_json with
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
              `String (scheduled_autonomous_cycle_outcome_to_string outcome)
          | None -> `Null );
        ( "proactive_outcome",
          match scheduled_autonomous_outcome with
          | Some outcome ->
              `String (scheduled_autonomous_cycle_outcome_to_string outcome)
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

let broadcast_lifecycle_events ~(name : string)
    ~(turn_generation : int)
    ~(compaction : Keeper_exec_context.compaction_event)
    ~(handoff_json : Yojson.Safe.t option) : unit =
  let now_ts = Time_compat.now () in
  (if compaction.applied then
     try
       Sse.broadcast
         (`Assoc
           [
             ("type", `String "keeper_compaction");
             ("name", `String name);
             ("generation", `Int turn_generation);
             ("before_tokens", `Int compaction.before_tokens);
             ("after_tokens", `Int compaction.after_tokens);
             ("saved_tokens", `Int compaction.saved_tokens);
             ( "trigger",
               match compaction.trigger with
               | Some trigger -> `String (Compaction_trigger.to_label trigger)
               | None ->
                   `String
                     (Keeper_exec_context.compaction_decision_to_string
                        compaction.decision) );
             ( "trigger_detail",
               match compaction.trigger with
               | Some trigger -> Compaction_trigger.to_detail_json trigger
               | None -> `Null );
             ("ts_unix", `Float now_ts);
           ])
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
         Log.Keeper.error "compaction SSE broadcast failed: %s"
           (Printexc.to_string exn);
         Prometheus.inc_counter Keeper_metrics.metric_keeper_metrics_sse_failures ~labels:[("kind", Keeper_metrics_sse_failure_kind.(to_label Compaction))] ());
  match handoff_json with
  | Some ((`Assoc _ as handoff)) ->
      let from_generation =
        Safe_ops.json_int ~default:turn_generation "from_generation" handoff
      in
      let to_generation =
        Safe_ops.json_int ~default:(from_generation + 1) "to_generation" handoff
      in
      let to_model = Safe_ops.json_string ~default:"" "to_model" handoff in
      (try
         Sse.broadcast
           (`Assoc
             [
               ("type", `String "keeper_handoff");
               ("name", `String name);
               ("from_generation", `Int from_generation);
               ("to_generation", `Int to_generation);
               ("from_model", `Null);
               ("to_model",
                if String.trim to_model = "" then `Null else `String to_model);
               ("ts_unix", `Float now_ts);
             ])
       with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          Log.Keeper.error "handoff SSE broadcast failed: %s"
            (Printexc.to_string exn);
          Prometheus.inc_counter Keeper_metrics.metric_keeper_metrics_sse_failures ~labels:[("kind", Keeper_metrics_sse_failure_kind.(to_label Handoff))] ())
  | _ -> ()

let update_metrics_from_failure (meta : keeper_meta) ~(latency_ms : int)
    ~(observation : Keeper_world_observation.world_observation)
    ~(reason : string) ?(is_transient = false) ?social_state
    ?social_transition_reason
    ?sdk_error
    () : keeper_meta =
  ignore is_transient; (* Param retained for caller compatibility; no longer
                          used internally after zombie-fix #5594. *)
  let now_ts = Time_compat.now () in
  record_keeper_idle_seconds
    ~keeper_name:meta.name
    ~idle_seconds:observation.idle_seconds;
  let is_scheduled_autonomous_cycle =
    is_scheduled_autonomous_cycle_of_observation observation
  in
  let public_reason =
    match sdk_error with
    | Some err -> (
        match Keeper_turn_driver.classify_masc_internal_error err with
        | Some (Keeper_turn_driver.Resumable_cli_session { detail; _ }) ->
            let trimmed = String.trim detail in
            if trimmed = "" then reason else trimmed
        | Some
            (Keeper_turn_driver.Oas_timeout_budget
               _ as err) ->
            Option.value
              ~default:reason
              (Keeper_turn_driver.summary_of_masc_internal_error err)
        | Some (Keeper_turn_driver.No_tool_capable_provider _ as err) -> (
            match Keeper_turn_driver.summary_of_masc_internal_error err with
            | Some summary -> summary
            | None -> reason)
        | _ -> reason)
    | None -> reason
  in
  let failure_counts_for_proactive_backoff =
    is_scheduled_autonomous_cycle
    &&
    match sdk_error with
    | Some err -> (
        match Keeper_turn_driver.classify_masc_internal_error err with
        | Some
            (Keeper_turn_driver.Oas_timeout_budget _
            | Keeper_turn_driver.Turn_timeout _
            | Keeper_turn_driver.Admission_queue_timeout _
            | Keeper_turn_driver.Admission_queue_rejected _
            | Keeper_turn_driver.Resumable_cli_session _
            | Keeper_turn_driver.No_tool_capable_provider _) ->
            true
        | Some _ | None -> false)
    | None -> false
  in
  (* #10474: emit Prometheus counters for no_tool_provider and proactive
     cycle outcomes so Grafana can surface fleet-wide health ratios. *)
  (match sdk_error with
   | Some err ->
       (match Keeper_turn_driver.classify_masc_internal_error err with
        | Some (Keeper_turn_driver.No_tool_capable_provider
	                  { cascade_name; _ }) ->
            let cascade_name =
              Keeper_turn_driver.cascade_name_to_string cascade_name
            in
            Prometheus.inc_counter
              Keeper_metrics.metric_keeper_no_tool_provider
              ~labels:
                [ ("keeper", meta.name)
                ; ("cascade", cascade_name)
                ]
              ()
        | _ -> ())
   | None -> ());
  if is_scheduled_autonomous_cycle then
    Prometheus.inc_counter Keeper_metrics.metric_keeper_proactive_outcome
      ~labels:[ ("keeper", meta.name); ("outcome", "error") ]
      ();
  let preview =
    let trimmed = String.trim public_reason in
    if trimmed = "" then "keeper cycle failed"
    else short_preview trimmed
  in
  {
    meta with
    updated_at = now_iso ();
    runtime = { meta.runtime with
      usage = { meta.runtime.usage with
        total_turns = meta.runtime.usage.total_turns + 1;
        last_turn_ts = now_ts;
        last_latency_ms = latency_ms;
      };
      proactive_rt = { meta.runtime.proactive_rt with
        count_total =
          meta.runtime.proactive_rt.count_total
          + (if is_scheduled_autonomous_cycle then 1 else 0);
        (* Always update last_ts on scheduled_autonomous attempts,
           including transient errors. Without this, transient errors
           (e.g. llama-server down) leave last_ts stale, causing
           cooldown_elapsed=false permanently → scheduled turns never
           resume. last_ts tracks attempts, not successes.
           Root cause of keeper zombie state: #5594. *)
        last_ts =
          if is_scheduled_autonomous_cycle then now_ts
          else meta.runtime.proactive_rt.last_ts;
        last_outcome =
          if is_scheduled_autonomous_cycle then Proactive_error
          else meta.runtime.proactive_rt.last_outcome;
        last_reason =
          if is_scheduled_autonomous_cycle
          then "unified:error:" ^ String.trim public_reason
          else meta.runtime.proactive_rt.last_reason;
        last_preview =
          if is_scheduled_autonomous_cycle then preview
          else meta.runtime.proactive_rt.last_preview;
        consecutive_noop_count =
          (if failure_counts_for_proactive_backoff then
             meta.runtime.proactive_rt.consecutive_noop_count + 1
           else meta.runtime.proactive_rt.consecutive_noop_count);
      };
      last_speech_act =
        (match social_state with
         | Some (state : Social.social_state) ->
             Social.speech_act_to_string state.speech_act
         | None -> meta.runtime.last_speech_act);
      last_social_transition_reason =
        (match social_transition_reason with
         | Some value -> String.trim value
         | None -> meta.runtime.last_social_transition_reason);
      last_active_desire =
        (match social_state with
         | Some (state : Social.social_state) ->
             Option.value ~default:"" state.active_desire
         | None -> meta.runtime.last_active_desire);
      last_current_intention =
        (match social_state with
         | Some (state : Social.social_state) ->
             Option.value ~default:"" state.current_intention
         | None -> meta.runtime.last_current_intention);
      last_blocker =
        (* Merge: typed klass from sdk_error becomes authoritative;
           detail picks up the social-state blocker text or a public-
           reason preview as observability context.  When the SDK
           error carries no typed mapping we refuse to fabricate a
           class — the previous string-only stamp is the substring
           anti-pattern this refactor closes (CLAUDE.md
           "워크어라운드 거부 기준 #2"). *)
        (match sdk_error with
         | Some err ->
             (match Keeper_status_bridge.blocker_class_of_sdk_error err with
              | Some klass ->
                  let detail =
                    match social_state with
                    | Some (state : Social.social_state) ->
                        Option.value ~default:"" state.blocker
                    | None -> short_preview public_reason
                  in
                  Some (Keeper_meta_contract.blocker_info_of_class
                          ~detail klass)
              | None -> None)
         | None -> None);
      last_need =
        (match social_state with
         | Some (state : Social.social_state) ->
             Option.value ~default:"" state.need
         | None -> meta.runtime.last_need);
    };
  }
