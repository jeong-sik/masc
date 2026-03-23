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
  {
    meta with
    updated_at = now_iso ();
    total_turns = meta.total_turns + 1;
    total_input_tokens = meta.total_input_tokens + result.usage.input_tokens;
    total_output_tokens = meta.total_output_tokens + result.usage.output_tokens;
    total_tokens =
      meta.total_tokens + Keeper_exec_context.total_tokens result.usage;
    total_cost_usd = meta.total_cost_usd +. turn_cost;
    last_turn_ts = now_ts;
    last_model_used = result.model_used;
    last_input_tokens = result.usage.input_tokens;
    last_output_tokens = result.usage.output_tokens;
    last_total_tokens = Keeper_exec_context.total_tokens result.usage;
    last_latency_ms = latency_ms;
    (* Proactive count: any turn that produced text or tools *)
    proactive_count_total =
      meta.proactive_count_total + (if has_text || has_tool_calls then 1 else 0);
    last_proactive_ts =
      (if has_text || has_tool_calls then now_ts else meta.last_proactive_ts);
    last_proactive_reason =
      (if has_tool_calls then
         Printf.sprintf "unified:tools=[%s]"
           (String.concat "," result.tools_used)
       else if has_text then "unified:text_response"
       else meta.last_proactive_reason);
    last_proactive_preview =
      (if has_text then short_preview result.response_text
       else if has_tool_calls then
         Printf.sprintf "(tools: %s)" (String.concat ", " result.tools_used)
       else meta.last_proactive_preview);
    (* Autonomous action tracking from tool calls *)
    autonomous_action_count =
      meta.autonomous_action_count + List.length result.tools_used;
    last_autonomous_action_at =
      (if has_tool_calls then now_iso () else meta.last_autonomous_action_at);
  }

let run_unified_turn ~(config : Room.config) ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(generation : int) : (keeper_meta, string) result =
  (* 1. Check API keys *)
  let model_labels =
    Keeper_coordination.effective_model_labels_for_turn meta ~inline_models:[]
  in
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
              ~temperature ~max_tokens
              ~max_cost_usd
              ~autonomy_filter:observation.autonomy_level
              ())
      in
      match run_result with
      | Error e -> Error e
      | Ok result ->
          (* 6. Observe result and update metrics *)
          let updated_meta =
            update_metrics_from_result meta ~latency_ms result
          in
          (* 7. Persist updated meta *)
          (match write_meta config updated_meta with
           | Ok () -> ()
           | Error msg ->
               Log.Keeper.error "write_meta failed after unified turn: %s" msg);
          Ok updated_meta
