(** Keeper_agent_run — Run a single keeper turn via OAS Agent.run().

    Owns the full context lifecycle: checkpoint loading, context creation,
    base system prompt application, and message persistence.
    Callers provide domain-specific system prompt logic via
    [build_turn_prompt] callback.

    Uses {!Keeper_tools_oas} for tool wrapping and
    {!Keeper_hooks_oas} for lifecycle hooks (checkpoint, metrics, social).

    @since Phase 5 — Context_manager encapsulation *)

(** Result of a single Agent.run() keeper turn. *)
type run_result = {
  response_text : string;
  model_used : string;
  turn_count : int;
  tool_calls_made : int;
  usage : Agent_sdk.Types.api_usage;
  tools_used : string list;
}

(** Run a single keeper turn via OAS Agent.run().

    Loads checkpoint, creates working context with the base keeper system
    prompt, then calls [build_turn_prompt] with the base prompt and message
    history so the caller can layer skill routing, continuity context,
    policy guards, and turn-specific instructions on top.

    After the callback returns the final system prompt, appends the user
    message, builds OAS tools + hooks, and delegates to
    [Oas_worker.run_named] which internally calls Agent.run().

    @param config Room configuration
    @param meta Keeper metadata
    @param base_dir Session base directory for checkpoints
    @param max_context Maximum context window tokens
    @param build_turn_prompt Callback: receives the base keeper system prompt
           and checkpoint message history, returns the final turn system prompt
    @param user_message The user's message to the keeper
    @param cascade_name Cascade profile name for model selection
    @param generation Current generation counter
    @param max_turns Maximum agent turns (default 3)
    @param guardrails Optional OAS guardrails for tool safety gates
    @param temperature MODEL temperature (default 0.3)
    @param max_tokens Maximum output tokens (default 4096) *)
let run_turn
    ~(config : Room.config)
    ~(meta : Keeper_types.keeper_meta)
    ~(base_dir : string)
    ~(max_context : int)
    ~(build_turn_prompt :
        base_system_prompt:string ->
        messages:Agent_sdk.Types.message list ->
        string)
    ~(user_message : string)
    ~(cascade_name : string)
    ~(generation : int)
    ?(max_turns : int = 10)
    ?guardrails
    ?(temperature : float = 0.3)
    ?(max_tokens : int = 4096)
    ?max_cost_usd
    ?on_event
    ?(autonomy_filter : string option)
    ()
  : (run_result, string) result =
  (* 1. Ensure session directory *)
  Keeper_types.mkdir_p base_dir;
  (* 2. Load checkpoint *)
  let (session, ctx_opt) =
    Keeper_exec_context.load_context_from_checkpoint
      ~trace_id:meta.trace_id
      ~primary_model_max_tokens:max_context
      ~base_dir
  in
  (* 3. Build base system prompt from meta *)
  let base_system_prompt =
    Keeper_prompt.build_keeper_system_prompt
      ~goal:meta.goal
      ~short_goal:meta.short_goal
      ~mid_goal:meta.mid_goal
      ~long_goal:meta.long_goal
      ~soul_profile:meta.soul_profile
      ~will:meta.will
      ~needs:meta.needs
      ~desires:meta.desires
      ~instructions:meta.instructions
  in
  (* 4. Create or restore working context, re-apply current prompt *)
  let base_ctx =
    match ctx_opt with
    | Some c -> c
    | None ->
      Keeper_exec_context.create
        ~system_prompt:base_system_prompt
        ~max_tokens:max_context
  in
  let ctx_work =
    Keeper_exec_context.set_system_prompt base_ctx
      ~system_prompt:base_system_prompt
  in
  (* 5. Build final turn system prompt via caller callback *)
  let turn_system_prompt =
    build_turn_prompt
      ~base_system_prompt
      ~messages:ctx_work.messages
  in
  (* 6. Append user message and persist *)
  let user_msg = Agent_sdk.Types.user_msg user_message in
  let ctx_work = Keeper_exec_context.append ctx_work user_msg in
  Keeper_exec_context.persist_message session user_msg;
  (* 7. Set up agent *)
  let ctx_ref = ref ctx_work in
  let agent_name = Printf.sprintf "keeper-%s" meta.name in
  let meta_ref = ref meta in
  let agent_ref : Agent_sdk.Agent.t option ref = ref None in
  let keeper_tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_ref in
  let extend_turns_tool = Keeper_extend_turns.make ~agent_ref ~max_turns () in
  let tools = extend_turns_tool :: keeper_tools in
  let hooks = Keeper_hooks_oas.make_hooks
    ~config ~meta_ref ~session ~ctx_ref ~generation ?max_cost_usd
    ?autonomy_filter () in
  let memory = Memory_oas_bridge.create_memory ~agent_name ~session_id:meta.trace_id () in
  ignore (Memory_oas_bridge.seed_institution ~memory ~config);
  ignore (Memory_oas_bridge.seed_procedures ~memory ~agent_name:"_global" ~limit:5);
  ignore (Memory_oas_bridge.seed_memory_bank ~memory ~agent_name ~limit:10);
  (* 5-tier: Episodic + Procedural seeding (in addition to Long_term above) *)
  ignore (Memory_oas_bridge.seed_episodes ~memory ~agent_name ~limit:30);
  ignore (Memory_oas_bridge.seed_procedures_as_oas ~memory ~agent_name ~limit:10);
  let reducer = Agent_sdk.Context_reducer.compose [
    { Agent_sdk.Context_reducer.strategy =
        Agent_sdk.Context_reducer.Prune_tool_outputs { max_output_len = 500 } };
    { strategy = Agent_sdk.Context_reducer.Merge_contiguous };
  ] in
  (* 8. Run Agent *)
  match
    Oas_worker.run_named
      ~cascade_name
      ~goal:user_message
      ~system_prompt:turn_system_prompt
      ~tools
      ~hooks
      ~context_reducer:reducer
      ~memory
      ~max_turns
      ~temperature
      ~max_tokens
      ?guardrails
      ?on_event
      ~agent_ref
      ()
  with
  | Error e -> Error e
  | Ok result ->
    let _flushed = Memory_oas_bridge.flush_all ~memory ~agent_name in
    let text = Agent_sdk.Types.text_of_content result.response.content in
    let model = result.response.model in
    let tool_names =
      List.filter_map (function
        | Agent_sdk.Types.ToolUse { name; _ } -> Some name | _ -> None)
        result.response.content
    in
    let usage = Keeper_exec_context.usage_of_response result.response in
    let assistant_msg = Agent_sdk.Types.assistant_msg text in
    Keeper_exec_context.persist_message session assistant_msg;
    ctx_ref := Keeper_exec_context.append !ctx_ref assistant_msg;
    Ok {
      response_text = text;
      model_used = model;
      turn_count = result.turns;
      tool_calls_made = List.length tool_names;
      usage;
      tools_used = tool_names;
    }
