(** Keeper_agent_run — Run a single keeper turn via OAS Agent.run().

    Owns the full context lifecycle: checkpoint loading, context creation,
    base system prompt application, and message persistence.
    Callers provide domain-specific system prompt logic via
    [build_turn_prompt] callback.

    Uses {!Keeper_tools_oas} for tool wrapping and
    {!Keeper_hooks_oas} for lifecycle hooks (checkpoint, metrics, social).

    @since Phase 5 — Keeper Agent.run encapsulation *)

(** Structured prompt result from [build_turn_prompt] callback.
    [system_prompt] contains hard constraints (identity, policy guards,
    tool guidance, direct-reply mode) that must stay in the system prompt.
    [dynamic_context] contains soft context (continuity, skill route,
    worktree changes, turn instructions) injected via OAS
    [extra_system_context] — prepended as a User message after reduction. *)
type turn_prompt = {
  system_prompt : string;
  dynamic_context : string;
}

(** Result of a single Agent.run() keeper turn. *)
type run_result = {
  response_text : string;
  model_used : string;
  turn_count : int;
  tool_calls_made : int;
  usage : Agent_sdk.Types.api_usage;
  tools_used : string list;
  checkpoint : Agent_sdk.Checkpoint.t option;
  proof : Agent_sdk.Cdal_proof.t option;
}

let normalize_response_text ~(text : string) ~(tool_names : string list) :
    (string, string) result =
  if String.trim text <> "" then Ok text
  else
    match tool_names with
    | [] -> Error "keeper turn completed with no textual reply"
    | _ ->
        Ok
          (Printf.sprintf "Completed without a textual reply. Tools used: %s."
             (String.concat ", " tool_names))

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
    @param temperature MODEL temperature override; when omitted, resolved
           from [Cascade_inference] with a 0.3 fallback
    @param max_tokens Maximum output tokens override; when omitted, resolved
           from [Cascade_inference] with a 4096 fallback *)
let run_turn
    ~(config : Room.config)
    ~(meta : Keeper_types.keeper_meta)
    ~(base_dir : string)
    ~(max_context : int)
    ~(build_turn_prompt :
        base_system_prompt:string ->
        messages:Agent_sdk.Types.message list ->
        turn_prompt)
    ~(user_message : string)
    ~(cascade_name : string)
    ~(generation : int)
    ?(max_turns : int = 50)
    ?(history_user_source = "direct_user")
    ?(history_assistant_source = "direct_assistant")
    ?guardrails
    ?temperature
    ?max_tokens
    ?max_cost_usd
    ?on_event
    ?(trajectory_acc : Trajectory.accumulator option)
    ?priority
    ()
  : (run_result, string) result =
  (* 0. Resolve inference parameters via Cascade_inference *)
  let temperature = match temperature with
    | Some t -> t
    | None ->
      Cascade_inference.resolve_temperature
        ~cascade_name
        ~fallback:(fun () -> 0.3)
  in
  let max_tokens = match max_tokens with
    | Some t -> t
    | None ->
      Cascade_inference.resolve_max_tokens
        ~cascade_name
        (* Keep under Cloudflare tunnel 100s timeout: 2048 / 35 tok/s ~ 59s *)
        ~fallback:(fun () -> 2048)
  in
  (* 1. Ensure session directory tree exists.
     Both the base traces dir AND the trace-specific session dir must
     exist before any file I/O (checkpoint load, history persist).
     In filesystem fallback mode (PG unavailable), these directories may
     not have been created by keeper_up if it only registered in-memory. *)
  let session_dir = Filename.concat base_dir meta.runtime.trace_id in
  Keeper_types.mkdir_p session_dir;
  (* 2. Load checkpoint *)
  let (session, ctx_opt) =
    Keeper_exec_context.load_context_from_checkpoint
      ~trace_id:meta.runtime.trace_id
      ~primary_model_max_tokens:max_context
      ~base_dir
  in
  (* 3. Build base system prompt from meta *)
  let persona_extended =
    Keeper_types_profile.load_persona_extended meta.name
    |> Option.value ~default:""
  in
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
      ~persona_extended
      ()
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
  (* 5. Build final turn system prompt via caller callback.
     Hard constraints stay in system_prompt; soft context is injected
     via OAS extra_system_context (prepended as User message after reduction). *)
  let { system_prompt = turn_system_prompt; dynamic_context } =
    build_turn_prompt
      ~base_system_prompt
      ~messages:ctx_work.messages
  in
  (* 6. Append user message and persist *)
  let user_msg = Agent_sdk.Types.user_msg user_message in
  (* Capture history BEFORE appending the current user_msg.
     OAS Agent.run appends user_msg from ~goal internally, so passing it
     in initial_messages would cause duplication. *)
  let history_messages = ctx_work.messages in
  let ctx_work = Keeper_exec_context.append ctx_work user_msg in
  Keeper_exec_context.persist_message ~source:history_user_source session user_msg;
  let checkpoint_sidecar =
    Keeper_exec_context.checkpoint_sidecar_json ~generation ctx_work
  in
  (* 7. Set up agent *)
  let ctx_ref = ref ctx_work in
  let agent_name = Printf.sprintf "keeper-%s" meta.name in
  let meta_ref = ref meta in
  let agent_ref : Agent_sdk.Agent.t option ref = ref None in
  let keeper_tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_ref in
  let extend_turns_tool = Keeper_extend_turns.make ~agent_ref ~max_turns () in
  let tools = extend_turns_tool :: keeper_tools in
  let base_hooks = Keeper_hooks_oas.make_hooks
    ~config ~meta_ref ~session ~ctx_ref ~generation ?max_cost_usd
    ?trajectory_acc
    () in
  (* Compose dynamic_context injection via extra_system_context.
     The before_turn_params hook fires each turn and sets
     extra_system_context, which OAS prepends as a User message
     after context reduction (agent_turn.ml:66-75). *)
  let hooks =
    if String.trim dynamic_context = "" then base_hooks
    else
      let inject_ctx : Agent_sdk.Hooks.hooks = {
        Agent_sdk.Hooks.empty with
        before_turn_params = Some (fun event ->
          match event with
          | Agent_sdk.Hooks.BeforeTurnParams { current_params; _ } ->
            let ctx = match current_params.extra_system_context with
              | None -> dynamic_context
              | Some existing -> existing ^ "\n\n" ^ dynamic_context
            in
            Agent_sdk.Hooks.AdjustParams
              { current_params with extra_system_context = Some ctx }
          | _ -> Agent_sdk.Hooks.Continue)
      } in
      Agent_sdk.Hooks.compose ~outer:inject_ctx ~inner:base_hooks
  in
  let base_dir = Filename.concat config.base_path ".masc" in
  let memory =
    Memory_oas_bridge.create_memory_full
      ~agent_name
      ~base_dir
      ~session_id:meta.runtime.trace_id
      ~config
      ~episode_limit:30
      ~procedure_limit:10
      ~global_procedure_limit:5
      ()
  in
  let reducer = Agent_sdk.Context_reducer.compose [
    Agent_sdk.Context_reducer.keep_last 30;
    { Agent_sdk.Context_reducer.strategy =
        Agent_sdk.Context_reducer.Prune_tool_outputs { max_output_len = 500 } };
    { strategy = Agent_sdk.Context_reducer.Merge_contiguous };
  ] in
  (* 8. Run Agent *)
  let contract =
    if Env_config.Cdal.enabled ()
    then Keeper_cdal_contract.of_keeper_meta meta
    else None
  in
  match
    Oas_worker.run_named
      ~cascade_name
      ~goal:user_message
      ~session_id:meta.runtime.trace_id
      ~system_prompt:turn_system_prompt
      ~tools
      ~initial_messages:history_messages
      ~hooks
      ~context_reducer:reducer
      ~memory
      ~max_turns
      ~max_idle_turns:5
      ~temperature
      ~max_tokens
      ?guardrails
      ?on_event
      ~agent_ref
      ?contract
      ~allowed_paths:(Keeper_alerting_path.effective_allowed_paths ~meta)
      ~working_context:checkpoint_sidecar
      ~priority:(Option.value priority ~default:Llm_provider.Request_priority.Interactive)
      ~cache_system_prompt:true
      ()
  with
  | Error e -> Error e
  | Ok result ->
    (match result.checkpoint with
     | Some checkpoint -> (
         try
           (* Unify session_id to trace_id so load_oas can find this
              checkpoint on the next turn. oas_worker generates a per-turn
              session_id that differs from trace_id, causing a load miss. *)
           let checkpoint =
             { checkpoint with Agent_sdk.Checkpoint.session_id = meta.runtime.trace_id }
           in
           Keeper_checkpoint_store.save_oas ~session_dir:session.session_dir
             checkpoint
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
             Log.Keeper.error "keeper:%s OAS checkpoint save failed: %s"
               meta.name (Printexc.to_string exn))
     | None ->
         Log.Keeper.warn "keeper:%s missing OAS checkpoint after run"
           meta.name);
    let _flushed = Memory_oas_bridge.flush_all ~memory ~agent_name in
    let text = Agent_sdk.Types.text_of_content result.response.content in
    let model = result.response.model in
    let tool_names =
      List.filter_map (function
        | Agent_sdk.Types.ToolUse { name; _ } -> Some name | _ -> None)
        result.response.content
    in
    let usage = Keeper_exec_context.usage_of_response result.response in
    (match normalize_response_text ~text ~tool_names with
     | Error e -> Error e
     | Ok response_text ->
         let assistant_msg = Agent_sdk.Types.assistant_msg response_text in
         Keeper_exec_context.persist_message
           ~source:history_assistant_source
           session assistant_msg;
         ctx_ref := Keeper_exec_context.append !ctx_ref assistant_msg;
         (match result.proof with
         | Some p ->
            Log.Keeper.info "keeper:%s proof: run_id=%s mode=%s status=%s evidence_refs=%d"
              meta.name p.run_id
              (Agent_sdk.Execution_mode.to_string p.effective_execution_mode)
              (Agent_sdk.Cdal_proof.show_result_status p.result_status)
              (List.length p.raw_evidence_refs);
            let store = Agent_sdk.Proof_store.default_config in
            let outcome = Cdal_eval_v1.evaluate ~store p in
            let verdict = Cdal_eval_v1.verdict_of_outcome outcome in
            Cdal_eval_v1.persist verdict;
            Log.Keeper.info
              "keeper:%s contract_verdict: status=%s scope=%s hash=%s"
              meta.name
              (Cdal_types.contract_status_to_string verdict.status)
              verdict.claim_scope
              verdict.judgment_hash;
            (match outcome with
             | Cdal_eval_v1.Load_failure (err, _) ->
               Log.Keeper.warn "keeper:%s contract_verdict load failure: %s"
                 meta.name (Cdal_loader.load_error_to_string err)
             | Cdal_eval_v1.Verdict (_, _) -> ());
            (match Cdal_eval_v1.friction_of_outcome outcome with
             | Some fp ->
               Log.Keeper.info
                 "keeper:%s friction: blocked=%d groups=%d tripwires=%d"
                 meta.name fp.blocked_attempt_count
                 (List.length fp.blocked_attempt_groups)
                 (List.length fp.review_tripwires)
             | None -> ())
          | None -> ());
         (* Post-turn deterministic memory write.
            Uses meta-based fallback when [STATE] parsing fails.
            See RFC #3646 Section 3: Det/NonDet boundary. *)
         (try
           let (notes_written, kinds_written) =
             Keeper_memory_bank.append_memory_notes_from_reply
               config meta ~turn:result.turns ~reply:response_text
           in
           if notes_written > 0 then
             Log.Keeper.info "keeper:%s memory_write: %d notes, kinds=[%s]"
               meta.name notes_written (String.concat "," kinds_written)
         with
         | exn ->
           Log.Keeper.warn "keeper:%s memory_write failed: %s"
             meta.name (Printexc.to_string exn));
         Ok {
           response_text;
           model_used = model;
           turn_count = result.turns;
           tool_calls_made = List.length tool_names;
           usage;
           tools_used = tool_names;
           checkpoint = result.checkpoint;
           proof = result.proof;
         })
