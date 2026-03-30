(** Keeper_unified_turn — Single entry point for keeper turns via OAS Agent.run().

    Replaces the 3-path dispatcher (social/proactive/autonomy) with a unified
    observe -> prompt -> Agent.run(tools, guardrails, hooks) loop.
    The model decides what to do; code only enforces safety and observes results.

    @since Unified Keeper Loop *)

open Keeper_types
open Keeper_memory [@@warning "-33"]
open Keeper_exec_context [@@warning "-33"]

(** Observe tool call history from run_result to update keeper metrics.
    No action_taken type — we observe what the agent did, not classify it. *)
let update_metrics_from_result (meta : keeper_meta) ~(latency_ms : int)
    ~(observation : Keeper_world_observation.world_observation)
    (result : Keeper_agent_run.run_result) : keeper_meta =
  let now_ts = Time_compat.now () in
  let used_model_id =
    let strip_latest s =
      if String.length s > 7 && String.sub s (String.length s - 7) 7 = ":latest"
      then String.sub s 0 (String.length s - 7) else s
    in
    let used = strip_latest result.model_used in
    let cascade_models = Oas_model_resolve.models_of_cascade_name meta.cascade_name in
    let cfgs = Llm_provider.Cascade_config.parse_model_strings cascade_models in
    match List.find_opt (fun (c : Llm_provider.Provider_config.t) ->
      c.model_id = result.model_used || c.model_id = used
    ) cfgs with
    | Some c -> c.model_id
    | None -> (match cfgs with c :: _ -> c.model_id | [] -> result.model_used)
  in
  let turn_cost =
    let pricing = Llm_provider.Pricing.pricing_for_model used_model_id in
    Llm_provider.Pricing.estimate_cost ~pricing
      ~input_tokens:result.usage.input_tokens
      ~output_tokens:result.usage.output_tokens ()
  in
  let has_tool_calls = result.tools_used <> [] in
  let has_text =
    String.trim result.response_text <> ""
  in
  let is_autonomous_turn = true in
  let is_board_reactive = observation.pending_board_events <> [] in
  let is_mention_reactive = observation.pending_mentions <> [] in
  let rt = meta.runtime in
  {
    meta with
    updated_at = now_iso ();
    runtime = { rt with
      usage = {
        total_turns = rt.usage.total_turns + 1;
        total_input_tokens = rt.usage.total_input_tokens + result.usage.input_tokens;
        total_output_tokens = rt.usage.total_output_tokens + result.usage.output_tokens;
        total_tokens =
          rt.usage.total_tokens + Keeper_exec_context.total_tokens result.usage;
        total_cost_usd = rt.usage.total_cost_usd +. turn_cost;
        last_turn_ts = now_ts;
        last_model_used = result.model_used;
        last_input_tokens = result.usage.input_tokens;
        last_output_tokens = result.usage.output_tokens;
        last_total_tokens = Keeper_exec_context.total_tokens result.usage;
        last_latency_ms = latency_ms;
      };
      (* Proactive count: any turn that produced text or tools *)
      proactive_rt = {
        count_total =
          rt.proactive_rt.count_total + (if has_text || has_tool_calls then 1 else 0);
        last_ts =
          (if has_text || has_tool_calls then now_ts else rt.proactive_rt.last_ts);
        last_reason =
          (if has_tool_calls then
             Printf.sprintf "unified:tools=[%s]"
               (String.concat "," result.tools_used)
           else if has_text then "unified:text_response"
           else rt.proactive_rt.last_reason);
        last_preview =
          (if has_text then short_preview result.response_text
           else if has_tool_calls then
             Printf.sprintf "(tools: %s)" (String.concat ", " result.tools_used)
           else rt.proactive_rt.last_preview);
      };
      (* Autonomous action tracking from tool calls *)
      autonomous_action_count =
        rt.autonomous_action_count + List.length result.tools_used;
      autonomous_turn_count =
        rt.autonomous_turn_count + (if is_autonomous_turn then 1 else 0);
      autonomous_text_turn_count =
        rt.autonomous_text_turn_count
        + (if is_autonomous_turn && has_text && not has_tool_calls then 1 else 0);
      autonomous_tool_turn_count =
        rt.autonomous_tool_turn_count
        + (if is_autonomous_turn && has_tool_calls then 1 else 0);
      board_reactive_turn_count =
        rt.board_reactive_turn_count + (if is_board_reactive then 1 else 0);
      mention_reactive_turn_count =
        rt.mention_reactive_turn_count + (if is_mention_reactive then 1 else 0);
      noop_turn_count =
        rt.noop_turn_count
        + (if is_autonomous_turn && not has_text && not has_tool_calls then 1 else 0);
      last_autonomous_action_at =
        (if has_tool_calls then now_iso () else rt.last_autonomous_action_at);
    };
  }

let append_metrics_snapshot ~(config : Room.config) ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(result : Keeper_agent_run.run_result) ~(latency_ms : int)
    ~(turn_cost : float)
    ~(context_ratio : float)
    ~(context_tokens : int)
    ~(context_max : int)
    ~(message_count : int)
    ~(handoff_json : Yojson.Safe.t option) : unit =
  let now_ts = Time_compat.now () in
  let channel =
    if observation.pending_mentions <> [] || observation.pending_board_events <> [] then
      "turn"
    else "proactive"
  in
  let work_kind =
    if result.tools_used <> [] then "tool_use"
    else if String.trim result.response_text <> "" then "text_turn"
    else "noop"
  in
  let metrics_store = keeper_metrics_store config meta.name in
  let snapshot =
    `Assoc
      [
        ("ts", `String (now_iso ()));
        ("ts_unix", `Float now_ts);
        ("channel", `String channel);
        ("name", `String meta.name);
        ("agent_name", `String meta.agent_name);
        ("trace_id", `String meta.runtime.trace_id);
        ("generation", `Int meta.runtime.generation);
        ("model_used", `String result.model_used);
        ( "usage",
          `Assoc
            [
              ("input_tokens", `Int result.usage.input_tokens);
              ("output_tokens", `Int result.usage.output_tokens);
              ("total_tokens",
               `Int (Keeper_exec_context.total_tokens result.usage));
            ] );
        ("latency_ms", `Int latency_ms);
        ("cost_usd", `Float turn_cost);
        ("context_ratio", `Float context_ratio);
        ("context_tokens", `Int context_tokens);
        ("context_max", `Int context_max);
        ("message_count", `Int message_count);
        ("continuity_state", `Null);
        ("continuity_summary", `String meta.continuity_summary);
        ("compacted", `Bool false);
        ("compaction_before_tokens", `Int context_tokens);
        ("compaction_after_tokens", `Int context_tokens);
        ("work_kind", `String work_kind);
        ("tool_call_count", `Int result.tool_calls_made);
        ("tools_used", `List (List.map (fun s -> `String s) result.tools_used));
        ("snapshot_source", `String "keeper_unified_turn");
        ("memory_check", memory_check_default_json ());
        ("handoff",
         match handoff_json with
         | Some value -> value
         | None -> `Assoc [ ("performed", `Bool false) ]);
        ("cdal_proof",
         match result.proof with
         | Some p ->
           `Assoc [
             ("run_id", `String p.Agent_sdk.Cdal_proof.run_id);
             ("effective_mode",
              Agent_sdk.Execution_mode.to_yojson p.effective_execution_mode);
             ("result_status",
              Agent_sdk.Cdal_proof.result_status_to_yojson p.result_status);
             ("violation_count",
              `Int (List.length p.raw_evidence_refs));
             ("tool_trace_count",
              `Int (List.length p.tool_trace_refs));
             ("mode_source", `String p.mode_decision_source);
           ]
         | None -> `Null);
      ]
  in
  Dated_jsonl.append metrics_store snapshot

let update_metrics_from_failure (meta : keeper_meta) ~(latency_ms : int)
    ~(reason : string) : keeper_meta =
  let now_ts = Time_compat.now () in
  let preview =
    let trimmed = String.trim reason in
    if trimmed = "" then "unified turn failed"
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
        last_reason = "unified:error:" ^ String.trim reason;
        last_preview = preview;
      };
    };
  }

let run_unified_turn ~(config : Room.config) ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(generation : int) : (keeper_meta, string) result =
  (* 1. Check API keys *)
  let model_labels = Keeper_coordination.effective_model_labels_for_turn meta in
  match ensure_api_keys_for_labels model_labels with
  | Error e -> Error e
  | Ok () ->
      let primary_max_context =
        Oas_model_resolve.resolve_primary_max_context model_labels
      in
      (* 2. Build unified prompt *)
      let system_prompt, user_message =
        Keeper_unified_prompt.build_prompt ~meta ~observation
      in
      let base_dir = session_base_dir config in
      (* Ensure session dir tree for filesystem fallback (issue #3019) *)
      Keeper_types.mkdir_p (Filename.concat base_dir meta.runtime.trace_id);
      (* 3. Derive parameters: cascade.json -> keeper env-var fallback *)
      let temperature =
        Cascade_inference.resolve_temperature
          ~cascade_name:"keeper_unified"
          ~fallback:Keeper_config.keeper_unified_temperature
      in
      let max_tokens =
        Cascade_inference.resolve_max_tokens
          ~cascade_name:"keeper_unified"
          ~fallback:Keeper_config.keeper_unified_max_tokens
      in
      let max_turns = Keeper_config.keeper_unified_max_turns () in
      let max_cost_usd = Keeper_config.keeper_tool_cost_max_usd () in
      (* 4. Build turn prompt callback: use our unified system prompt *)
      let build_turn_prompt ~base_system_prompt:_ ~messages:_ =
        system_prompt
      in
      (* 5. Run via OAS Agent.run() *)
      let run_result, latency_ms =
        Keeper_exec_context.timed (fun () ->
            Keeper_agent_run.run_turn ~config ~meta ~base_dir
              ~max_context:primary_max_context ~build_turn_prompt
              ~user_message ~cascade_name:"keeper_unified"
              ~generation ~max_turns
              ~history_user_source:"world_state_prompt"
              ~history_assistant_source:"internal_assistant"
              ~temperature ~max_tokens
              ~max_cost_usd
              ())
      in
      match run_result with
      | Error e ->
          let updated_meta =
            update_metrics_from_failure meta ~latency_ms ~reason:e
          in
          (match write_meta config updated_meta with
           | Ok () -> ()
           | Error msg ->
               Log.Keeper.error
                 "write_meta failed after unified turn failure: %s" msg);
          let base_path = config.base_path in
          Keeper_registry.increment_turn_failures ~base_path meta.name;
          let count = Keeper_registry.get_turn_failures ~base_path meta.name in
          let threshold =
            Runtime_params.get Governance_registry.keeper_max_turn_failures
          in
          if count >= threshold then begin
            Log.Keeper.error
              "%s: %d consecutive turn failures (threshold=%d), marking crashed"
              meta.name count threshold;
            let reason = Keeper_registry.Turn_consecutive_failures count in
            Keeper_registry.set_failure_reason ~base_path meta.name (Some reason);
            Keeper_registry.set_state ~base_path meta.name
              Keeper_registry.Crashed;
            Keeper_registry.record_crash ~base_path meta.name
              (Time_compat.now ())
              (Keeper_registry.failure_reason_to_string reason);
            Keeper_registry.record_error ~base_path meta.name
              (Printf.sprintf "turn_consecutive_failures(%d)" count)
          end;
          Error e
      | Ok result ->
          let used_model_id =
            let strip_latest s =
              if
                String.length s > 7
                && String.sub s (String.length s - 7) 7 = ":latest"
              then String.sub s 0 (String.length s - 7)
              else s
            in
            let used = strip_latest result.model_used in
            let cascade_models =
              Oas_model_resolve.models_of_cascade_name meta.cascade_name
            in
            let cfgs =
              Llm_provider.Cascade_config.parse_model_strings cascade_models
            in
            match
              List.find_opt
                (fun (c : Llm_provider.Provider_config.t) ->
                  c.model_id = result.model_used || c.model_id = used)
                cfgs
            with
            | Some c -> c.model_id
            | None ->
                (match cfgs with
                | c :: _ -> c.model_id
                | [] -> result.model_used)
          in
          let turn_cost =
            let pricing =
              Llm_provider.Pricing.pricing_for_model used_model_id
            in
            Llm_provider.Pricing.estimate_cost ~pricing
              ~input_tokens:result.usage.input_tokens
              ~output_tokens:result.usage.output_tokens ()
          in
          let rollover =
            maybe_rollover_oas_handoff ~base_dir
              ~meta
              ~model:result.model_used
              ~primary_model_max_tokens:primary_max_context
              ~checkpoint:result.checkpoint
          in
          (* 6. Observe result and update metrics *)
          let updated_meta =
            update_metrics_from_result rollover.updated_meta ~latency_ms
              ~observation result
          in
          (try
             append_metrics_snapshot ~config ~meta:updated_meta ~observation
               ~result ~latency_ms ~turn_cost
               ~context_ratio:rollover.context_ratio
               ~context_tokens:rollover.context_tokens
               ~context_max:rollover.context_max
               ~message_count:rollover.message_count
               ~handoff_json:rollover.handoff_json
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
               Log.Keeper.error
                 "write metrics snapshot failed after unified turn: %s"
                 (Printexc.to_string exn));
          (* 7. Persist updated meta *)
          (match write_meta config updated_meta with
           | Ok () -> ()
           | Error msg ->
               Log.Keeper.error "write_meta failed after unified turn: %s" msg);
          (* 8. Reset turn failure counter on success *)
          Keeper_registry.reset_turn_failures ~base_path:config.base_path
            meta.name;
          Ok updated_meta
