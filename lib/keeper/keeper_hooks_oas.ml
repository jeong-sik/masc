(** Keeper_hooks_oas — OAS hooks adapter for Keeper Agent.run().

    Maps keeper-specific behaviors (checkpoint, metrics, social events)
    to OAS hook events. Used with {!Keeper_tools_oas} to run Keeper
    via Agent.run() instead of a manual turn loop.

    @since Phase 4 — Keeper → Agent.run() migration *)

(** Build OAS hooks for a keeper agent.

    @param config Room configuration
    @param meta_ref Mutable ref to keeper metadata
    @param session Session context for checkpoint persistence
    @param ctx_ref Mutable ref to current working context
    @param generation Current generation counter
    @param on_tool_executed Optional callback after each tool execution *)
let make_hooks
    ~(config : Room.config)
    ~(meta_ref : Keeper_types.keeper_meta ref)
    ~(session : Context_manager.session_context)
    ~(ctx_ref : Context_manager.working_context ref)
    ~(generation : int)
    ?(on_tool_executed : string -> Yojson.Safe.t -> string -> unit =
        fun _ _ _ -> ())
    ()
  : Agent_sdk.Hooks.hooks =
  ignore config;
  let board_write_tools =
    [ "keeper_board_post"; "keeper_board_comment"; "keeper_board_vote" ]
  in
  { Agent_sdk.Hooks.empty with

    after_turn = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.AfterTurn { turn; response } ->
        let ctx = !ctx_ref in
        let _ckpt = Keeper_exec_context.save_checkpoint
          session ctx ~generation in
        let model = response.Llm_provider.Types.model in
        let usage = match response.usage with
          | Some u -> u.input_tokens + u.output_tokens
          | None -> 0
        in
        Log.Keeper.info "keeper:%s turn=%d model=%s tokens=%d"
          (!meta_ref).name turn model usage;
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);

    post_tool_use = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.PostToolUse { tool_name; input; output; _ } ->
        let output_text = match output with
          | Ok { Llm_provider.Types.content; _ } -> content
          | Error { Llm_provider.Types.message; _ } ->
            Printf.sprintf "error: %s" message
        in
        on_tool_executed tool_name input output_text;
        if List.mem tool_name board_write_tools then
          Log.Keeper.info "keeper:%s social_event tool=%s"
            (!meta_ref).name tool_name;
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);

    pre_tool_use = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.PreToolUse { tool_name; _ } ->
        ignore tool_name;
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);

    on_idle = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.OnIdle { consecutive_idle_turns; _ } ->
        Log.Keeper.info "keeper:%s idle_turns=%d"
          (!meta_ref).name consecutive_idle_turns;
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);
  }
