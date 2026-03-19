(** Perpetual_oas_hooks — OAS lifecycle hooks for perpetual agent.

    Extracted from [perpetual_oas.ml]. Creates 4 OAS hooks (before_turn,
    after_turn, on_idle, pre_tool_use) and a periodic heartbeat callback.

    Dependencies: [Perpetual_oas_state], [Context_compact_oas],
    [Context_manager], [Verifier_oas], [Compaction_types].

    @since 2.111.0 — H2 God File split *)

open Printf

module Oas = Agent_sdk

(** Create OAS hooks that implement perpetual loop lifecycle.

    - BeforeTurn: increment turn counter, check context thresholds
      (compact/prepare/handoff), inject context ratio into system messages.
    - AfterTurn: update metrics (tokens, cost), track idle turns based on
      whether tool calls occurred.
    - OnIdle: when consecutive idle turns exceed [max_idle], signal stop.
    - PreToolUse: delegates to Phase 4 verifier hook when feedback is enabled.

    @param config The perpetual loop configuration.
    @param pstate Mutable perpetual state (shared across turns).
    @param emit Event emitter closure from perpetual_loop.
    @param ctx_ref Reference to the current working context (for ratio checks). *)
let perpetual_hooks
    ~(config : Perpetual_loop.loop_config)
    ~(pstate : Perpetual_oas_state.perpetual_state)
    ~(emit : Perpetual_loop.event -> unit)
    ~(ctx_ref : Context_manager.working_context ref)
  : Oas.Hooks.hooks =
  let before_turn : Oas.Hooks.hook = fun event ->
    match event with
    | Oas.Hooks.BeforeTurn { turn; _ } ->
      Perpetual_oas_state.update_state (fun ps ->
        ps.turn_count <- turn) pstate;
      emit (TurnStart turn);
      (* Check thresholds against current context *)
      let ratio = Context_manager.context_ratio !ctx_ref in
      (* Compact threshold: apply context reduction via Phase 1 adapter *)
      if ratio >= config.compact_threshold then begin
        let before = (!ctx_ref).token_count in
        (* Both Context_manager.compaction_strategy and Context_compact_oas.strategy
           are now aliases for Compaction_types.compaction_strategy — no mapping needed. *)
        let strategies = config.compact_strategies in
        let compacted_msgs, new_token_count =
          Context_compact_oas.compact
            ~system_prompt:(!ctx_ref).system_prompt
            ~messages:(!ctx_ref).messages
            ~strategies
        in
        ctx_ref := {
          !ctx_ref with
          messages = compacted_msgs;
          token_count = new_token_count;
        };
        let after = new_token_count in
        Perpetual_oas_state.update_state (fun ps ->
          ps.compaction_count <- ps.compaction_count + 1) pstate;
        emit (Compacted {
          before_tokens = before;
          after_tokens = after;
          offloaded_path = None;
        })
      end;
      (* Handoff threshold: signal generation handoff *)
      let ratio2 = Context_manager.context_ratio !ctx_ref in
      if ratio2 >= config.handoff_threshold then begin
        let next_model = match config.model_cascade with
          | _ :: m :: _ -> m
          | [m] -> m
          | [] -> Llm_cascade.default_local_model_spec ()
        in
        Perpetual_oas_state.update_state (fun ps ->
          ps.handoff_triggered <- true;
          ps.running <- false) pstate;
        emit (Handoff {
          to_model = next_model.model_id;
          generation = pstate.generation + 1;
        })
      end;
      Oas.Hooks.Continue
    | _ -> Oas.Hooks.Continue
  in
  let after_turn : Oas.Hooks.hook = fun event ->
    match event with
    | Oas.Hooks.AfterTurn { turn; response } ->
      (* Track tokens from response usage *)
      let tokens_used = match response.usage with
        | Some u -> u.input_tokens + u.output_tokens
        | None -> 0
      in
      (* Check for tool calls to determine idle state *)
      let has_tool_use = List.exists (function
        | Oas.Types.ToolUse _ -> true
        | _ -> false
      ) response.content in
      Perpetual_oas_state.update_state (fun ps ->
        ps.total_tokens <- ps.total_tokens + tokens_used;
        if has_tool_use then
          ps.idle_turns <- 0
        else
          ps.idle_turns <- ps.idle_turns + 1) pstate;
      (* Check for goal completion or stuck signals in response text *)
      let text = List.filter_map (function
        | Oas.Types.Text s -> Some s
        | _ -> None
      ) response.content |> String.concat "\n" in
      let upper = String.uppercase_ascii text in
      if (try ignore (Str.search_forward
            (Str.regexp_string "[GOAL_COMPLETE]") upper 0); true
          with Not_found -> false) then begin
        Perpetual_oas_state.update_state (fun ps ->
          ps.running <- false) pstate;
        emit (Terminated "Goal complete (OAS)")
      end
      else if (try ignore (Str.search_forward
            (Str.regexp_string "[STUCK") upper 0); true
          with Not_found -> false) then begin
        Perpetual_oas_state.update_state (fun ps ->
          ps.running <- false) pstate;
        emit (Terminated "Agent stuck (OAS)")
      end;
      emit (TurnEnd { turn; tokens_used; cost = 0.0 });
      Oas.Hooks.Continue
    | _ -> Oas.Hooks.Continue
  in
  let on_idle : Oas.Hooks.hook = fun event ->
    match event with
    | Oas.Hooks.OnIdle { consecutive_idle_turns; _ } ->
      Perpetual_oas_state.update_state (fun ps ->
        ps.idle_turns <- consecutive_idle_turns) pstate;
      if consecutive_idle_turns >= config.max_idle_turns then begin
        Perpetual_oas_state.update_state (fun ps ->
          ps.running <- false) pstate;
        emit (IdleDetected consecutive_idle_turns);
        emit (Terminated "Max idle turns reached (OAS)");
        Oas.Hooks.Skip
      end else
        Oas.Hooks.Continue
    | _ -> Oas.Hooks.Continue
  in
  let pre_tool_use =
    if config.feedback_enabled then
      Some (Verifier_oas.make_pre_tool_hook
        ~goal:config.initial_goal
        ~context_summary:(sprintf "Turn %d, generation %d"
          pstate.turn_count pstate.generation))
    else
      None
  in
  {
    Oas.Hooks.empty with
    before_turn = Some before_turn;
    after_turn = Some after_turn;
    on_idle = Some on_idle;
    pre_tool_use;
  }

(** Create an OAS periodic_callback that emits MASC heartbeat events.

    Mirrors the heartbeat logic in [Perpetual_loop.run_turn]:
    if [heartbeat_interval_s] has elapsed since last heartbeat,
    emit a Heartbeat event with current turn and context percentage.

    @param config Loop config (for interval).
    @param pstate Mutable perpetual state (for last_heartbeat tracking).
    @param emit Event emitter.
    @param ctx_ref Current working context reference. *)
let perpetual_periodic_callbacks
    ~(config : Perpetual_loop.loop_config)
    ~(pstate : Perpetual_oas_state.perpetual_state)
    ~(emit : Perpetual_loop.event -> unit)
    ~(ctx_ref : Context_manager.working_context ref)
  : Oas.Agent.periodic_callback list =
  [{
    Oas.Agent_types.interval_sec = config.heartbeat_interval_s;
    callback = (fun () ->
      let now = Time_compat.now () in
      let turn = Perpetual_oas_state.with_state (fun ps ->
        ps.last_heartbeat <- now;
        ps.turn_count) pstate in
      let pct = Context_manager.context_ratio !ctx_ref *. 100.0 in
      emit (Heartbeat { turn; context_pct = pct })
    );
  }]
