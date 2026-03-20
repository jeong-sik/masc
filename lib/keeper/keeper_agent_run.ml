(** Keeper_agent_run — Run a single keeper turn via OAS Agent.run().

    Replaces the manual LLM call + tool dispatch loop in keeper_turn.ml
    with Agent.run(). Uses {!Keeper_tools_oas} for tool wrapping and
    {!Keeper_hooks_oas} for lifecycle hooks (checkpoint, metrics, social).

    This is the Phase C entry point of Issue #1797.
    Callers can switch between the old manual loop and this function
    via [KEEPER_USE_AGENT_RUN=true] environment variable.

    @since Phase 4 — Keeper → Agent.run() migration *)

(** Result of a single Agent.run() keeper turn. *)
type run_result = {
  response_text : string;
  model_used : string;
  turn_count : int;
  tool_calls_made : int;
}

(** Run a single keeper turn via OAS Agent.run().

    Builds OAS Tool.t from keeper tools, attaches keeper hooks
    (checkpoint, metrics, social events), and delegates to
    [Oas_worker.run_named] which internally calls Agent.run().

    @param config Room configuration
    @param meta Keeper metadata
    @param session Session context for persistence
    @param ctx_ref Mutable ref to working context
    @param system_prompt Full system prompt for the turn
    @param user_message The user's message to the keeper
    @param cascade_name Cascade profile name for model selection
    @param generation Current generation counter *)
let run_turn
    ~(config : Room.config)
    ~(meta : Keeper_types.keeper_meta)
    ~(session : Context_manager.session_context)
    ~(ctx_ref : Context_manager.working_context ref)
    ~(system_prompt : string)
    ~(user_message : string)
    ~(cascade_name : string)
    ~(generation : int)
    ()
  : (run_result, string) result =
  let meta_ref = ref meta in
  let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_ref in
  let hooks = Keeper_hooks_oas.make_hooks
    ~config ~meta_ref ~session ~ctx_ref ~generation () in
  let reducer = Agent_sdk.Context_reducer.compose [
    { Agent_sdk.Context_reducer.strategy =
        Agent_sdk.Context_reducer.Prune_tool_outputs { max_output_len = 500 } };
    { strategy = Agent_sdk.Context_reducer.Merge_contiguous };
  ] in
  match
    Oas_worker.run_named
      ~cascade_name
      ~goal:user_message
      ~system_prompt
      ~tools
      ~hooks
      ~context_reducer:reducer
      ~max_turns:3
      ~temperature:0.3
      ~max_tokens:4096
      ()
  with
  | Error e -> Error e
  | Ok result ->
    let text = Agent_sdk.Types.text_of_content result.response.content in
    let model = result.response.Llm_provider.Types.model in
    let tool_count =
      List.length (List.filter (function
        | Agent_sdk.Types.ToolUse _ -> true | _ -> false)
        result.response.content)
    in
    (* Persist assistant response to session *)
    let assistant_msg = Llm_provider.Types.assistant_msg text in
    Context_manager.persist_message session assistant_msg;
    ctx_ref := Context_manager.append !ctx_ref assistant_msg;
    Ok {
      response_text = text;
      model_used = model;
      turn_count = result.turns;
      tool_calls_made = tool_count;
    }

(** Check if Agent.run() path is enabled via environment variable. *)
let is_enabled () =
  match Sys.getenv_opt "KEEPER_USE_AGENT_RUN" with
  | Some v ->
    let v = String.lowercase_ascii (String.trim v) in
    v = "true" || v = "1" || v = "yes"
  | None -> false
