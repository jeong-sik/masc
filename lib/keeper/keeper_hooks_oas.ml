(** Keeper_hooks_oas — OAS hooks adapter for Keeper Agent.run().

    Maps keeper-specific behaviors (checkpoint, metrics, social events,
    safety gates) to OAS hook events.

    Safety checks in [pre_tool_use]:
    - Cost budget: reject tool calls when accumulated cost exceeds limit
    - Destructive patterns: reject bash/edit tools with dangerous commands
      (rm -rf, drop table, force push, etc.)

    These checks were previously in [Eval_gate.guarded_execute] and are
    now natively integrated into the Agent.run() hook lifecycle.

    @since Phase 4 — Keeper → Agent.run() migration
    @since Phase 7 — Eval_gate → OAS hooks migration *)

(** Bash-like tools that need destructive pattern screening. *)
let destructive_check_tools =
  [ "keeper_bash"; "keeper_fs_edit"; "keeper_edit" ]

(** Extract command or content string from tool input JSON for screening. *)
let extract_command_from_input (input : Yojson.Safe.t) : string =
  let open Yojson.Safe.Util in
  try
    match input |> member "command" with
    | `String s -> s
    | `Null | _ ->
      (match input |> member "content" with
       | `String s -> s
       | _ -> "")
  with Yojson.Safe.Util.Type_error _ -> ""

(** Tools allowed at each autonomy level for the unified turn path.
    Returns None if no filtering should be applied (AllowAll). *)
let allowed_tools_for_autonomy_level
    (level : string) : string list option =
  let base_safe = [
    "keeper_board_get"; "keeper_board_post"; "keeper_board_comment";
    "keeper_board_vote"; "keeper_board_list";
    "keeper_read"; "keeper_fs_read";
    "keeper_memory_search";
    "keeper_time_now"; "keeper_context_status";
    "extend_turns";
  ] in
  match String.lowercase_ascii (String.trim level) with
  | "l4_autonomous" -> Some ("keeper_bash" :: base_safe)
  | "l5_independent" -> None  (* AllowAll *)
  | _ -> Some base_safe  (* L1/L2/L3 and unknown: safe tools only *)

(** Build OAS hooks for a keeper agent.

    @param config Room configuration
    @param meta_ref Mutable ref to keeper metadata
    @param session Session context for checkpoint persistence
    @param ctx_ref Mutable ref to current working context
    @param generation Current generation counter
    @param max_cost_usd Optional cost budget (rejects tool calls above limit)
    @param destructive_check Enable destructive pattern detection (default true)
    @param on_tool_executed Optional callback after each tool execution
    @param autonomy_filter Optional autonomy level for tool visibility gating *)
let make_hooks
    ~(config : Room.config)
    ~(meta_ref : Keeper_types.keeper_meta ref)
    ~(session : Context_manager.session_context)
    ~(ctx_ref : Context_manager.working_context ref)
    ~(generation : int)
    ?(max_cost_usd : float option)
    ?(destructive_check : bool = true)
    ?(on_tool_executed : string -> Yojson.Safe.t -> string -> unit =
        fun _ _ _ -> ())
    ?(autonomy_filter : string option)
    ()
  : Agent_sdk.Hooks.hooks =
  ignore config;
  let board_write_tools =
    [ "keeper_board_post"; "keeper_board_comment"; "keeper_board_vote" ]
  in
  let autonomy_allowed =
    match autonomy_filter with
    | None -> None
    | Some level -> allowed_tools_for_autonomy_level level
  in
  { Agent_sdk.Hooks.empty with

    after_turn = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.AfterTurn { turn; response } ->
        let ctx = !ctx_ref in
        let _ckpt = Keeper_exec_context.save_checkpoint
          session ctx ~generation in
        let model = response.model in
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
          | Ok { Agent_sdk.Types.content; _ } -> content
          | Error { Agent_sdk.Types.message; _ } ->
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
      | Agent_sdk.Hooks.PreToolUse { tool_name; input; accumulated_cost_usd; _ } ->
        (* Safety gate 1: Cost budget *)
        (match max_cost_usd with
         | Some limit when accumulated_cost_usd >= limit ->
           Log.Keeper.warn "keeper:%s cost gate: $%.4f >= $%.4f limit, skipping %s"
             (!meta_ref).name accumulated_cost_usd limit tool_name;
           Agent_sdk.Hooks.Skip
         | _ ->
           (* Safety gate 2: Autonomy-level tool visibility *)
           let autonomy_blocked =
             match autonomy_allowed with
             | None -> false  (* AllowAll *)
             | Some allowed -> not (List.mem tool_name allowed)
           in
           if autonomy_blocked then (
             Log.Keeper.info "keeper:%s autonomy gate: %s not in allowed set, skipping"
               (!meta_ref).name tool_name;
             Agent_sdk.Hooks.Skip)
           else
           (* Safety gate 3: Destructive pattern detection *)
           if destructive_check && List.mem tool_name destructive_check_tools then
             let cmd = extract_command_from_input input in
             match Eval_gate.detect_destructive cmd with
             | Some (pattern, desc) ->
               Log.Keeper.warn "keeper:%s destructive pattern in %s: '%s' (%s)"
                 (!meta_ref).name tool_name pattern desc;
               Agent_sdk.Hooks.Skip
             | None -> Agent_sdk.Hooks.Continue
           else
             Agent_sdk.Hooks.Continue)
      | _ -> Agent_sdk.Hooks.Continue);

    on_idle = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.OnIdle { consecutive_idle_turns; _ } ->
        Log.Keeper.info "keeper:%s idle_turns=%d"
          (!meta_ref).name consecutive_idle_turns;
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);
  }
