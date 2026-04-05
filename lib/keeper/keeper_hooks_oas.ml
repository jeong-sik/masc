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
  [ "keeper_bash"; "keeper_fs_edit"; "keeper_github" ]

(** Keeper deny list — derived from Tool_catalog surface SSOT.
    Administrative/destructive operations that should only be invoked
    by operators or through controlled workflows.
    Inspired by Trail of Bits' deny-rule pattern. *)
let keeper_denied_tools =
  Tool_catalog.tools_for_surface Tool_catalog.Keeper_denied

(** Percent-encode field value for structured [tool_skipped] output.
    Matches [Keeper_agent_run.escape_field_value] encoding.
    Local copy to avoid circular dependency. *)
let escape_field s =
  let buf = Buffer.create (String.length s * 3 / 2 + 1) in
  String.iter (fun ch ->
    match ch with
    | ' ' -> Buffer.add_string buf "%20"
    | '=' -> Buffer.add_string buf "%3D"
    | '\n' -> Buffer.add_string buf "%0A"
    | '\r' -> Buffer.add_string buf "%0D"
    | '\t' -> Buffer.add_string buf "%09"
    | '%' -> Buffer.add_string buf "%25"
    | _ -> Buffer.add_char buf ch) s;
  Buffer.contents buf

(** Render structured skip reason for inline Override injection.
    The LLM sees this as the ToolResult content immediately within
    the same turn, enabling in-turn reasoning about alternatives.
    @since Phase 8 — Skip→Override migration *)
let render_inline_skip_reason ~tool_name ~reason_code ~reason_text : string =
  let replacement_hint =
    match (Tool_catalog.metadata tool_name).Tool_catalog.replacement with
    | Some replacement ->
      Printf.sprintf " replacement=%s" (escape_field replacement)
    | None -> ""
  in
  Printf.sprintf
    "[tool_skipped] tool=%s source=keeper_hook code=%s reason=%s%s"
    (escape_field tool_name)
    (escape_field reason_code)
    (escape_field reason_text)
    replacement_hint

(** Broadcast a tool skip event via SSE for dashboard visibility. *)
let broadcast_tool_skipped ~keeper_name ~tool_name ~reason_code =
  (try
    Sse.broadcast
      (`Assoc [
        ("type", `String "keeper_tool_skipped");
        ("name", `String keeper_name);
        ("tool_name", `String tool_name);
        ("reason_code", `String reason_code);
        ("ts_unix", `Float (Unix.gettimeofday ()));
      ])
  with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ())

(** Extract command or content string from tool input JSON for screening.
    Reads "command", "cmd" (keeper_github), or "content" keys. *)
let extract_command_from_input (input : Yojson.Safe.t) : string =
  let open Yojson.Safe.Util in
  try
    match input |> member "command" with
    | `String s -> s
    | `Null | _ ->
      (match input |> member "cmd" with
       | `String s -> s
       | `Null | _ ->
         (match input |> member "content" with
          | `String s -> s
          | _ -> ""))
  with Yojson.Safe.Util.Type_error _ -> ""

(** Append a cost event to .masc/costs.jsonl for per-task cost attribution.
    Schema matches bin/masc_cost.ml with an additional "source" field to
    distinguish automatic entries from manual CLI entries.

    Called from [after_turn] hook when a trajectory accumulator is present. *)
let emit_cost_event
    ~(masc_root : string)
    ~(agent_name : string)
    ~(task_id : string option)
    ~(model : string)
    ~(input_tokens : int)
    ~(output_tokens : int)
    ~(cost_usd : float)
    : unit =
  let path = Filename.concat masc_root "costs.jsonl" in
  let entry = `Assoc [
    ("agent", `String agent_name);
    ("task_id", Json_util.string_opt_to_json task_id);
    ("model", `String model);
    ("input_tokens", `Int input_tokens);
    ("output_tokens", `Int output_tokens);
    ("cost_usd", `Float cost_usd);
    ("timestamp", `String (Types.now_iso ()));
    ("source", `String "auto_trajectory");
  ] in
  let line = Yojson.Safe.to_string entry ^ "\n" in
  (try Fs_compat.append_file path line
   with Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Keeper.error "emit_cost_event: failed to write %s: %s"
          path (Printexc.to_string exn))

(** Build OAS hooks for a keeper agent.

    All keepers receive the full tool set unconditionally.
    Safety is enforced through eval_gate deny lists and these hooks:
    1. Cost budget — reject when accumulated cost exceeds limit
    2. Destructive pattern detection — reject dangerous bash/edit commands
    3. Cost event emission — auto-emit per-turn cost to .masc/costs.jsonl

    @param config Room configuration
    @param meta_ref Mutable ref to keeper metadata
    @param session Session context for checkpoint persistence
    @param ctx_ref Mutable ref to current working context
    @param generation Current generation counter
    @param max_cost_usd Optional cost budget (rejects tool calls above limit)
    @param destructive_check Enable destructive pattern detection (default true)
    @param on_tool_executed Optional callback after each tool execution
    @param trajectory_acc Optional trajectory accumulator for cost attribution *)
let make_hooks
    ~config:(_config : Room.config)
    ~(meta_ref : Keeper_types.keeper_meta ref)
    ~session:(_session : Keeper_exec_context.session_context)
    ~ctx_ref:(_ctx_ref : Keeper_exec_context.working_context ref)
    ~(generation : int)
    ?(max_cost_usd : float option)
    ?(destructive_check : bool = true)
    ?(on_tool_executed : string -> Yojson.Safe.t -> string -> unit =
        fun _ _ _ -> ())
    ?(trajectory_acc : Trajectory.accumulator option)
    ()
  : Agent_sdk.Hooks.hooks =
  let sse_turn_complete = "keeper_turn_complete" in
  let board_write_tools =
    [ "keeper_board_post"; "keeper_board_comment"; "keeper_board_vote" ]
  in
  { Agent_sdk.Hooks.empty with

    after_turn = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.AfterTurn { turn; response } ->
        let meta = !meta_ref in
        let model = response.model in
        let input_tok, output_tok = match response.usage with
          | Some u -> (u.input_tokens, u.output_tokens)
          | None -> (0, 0)
        in
        let total_tok = input_tok + output_tok in
        (* Provider prefix cache token tracking (Anthropic).
           Non-Anthropic providers report 0 for these fields. *)
        (match response.usage with
         | Some u ->
           let cc = u.cache_creation_input_tokens in
           let cr = u.cache_read_input_tokens in
           if cc > 0 then
             Prometheus.inc_counter
               "masc_provider_prefix_cache_creation_tokens_total"
               ~delta:(Float.of_int cc) ();
           if cr > 0 then
             Prometheus.inc_counter
               "masc_provider_prefix_cache_read_tokens_total"
               ~delta:(Float.of_int cr) ()
         | None -> ());
        Log.Keeper.info "keeper:%s turn=%d total_turns=%d model=%s tokens=%d"
          meta.name turn meta.runtime.usage.total_turns model total_tok;
        (* Emit per-turn cost event for task attribution.
           cost_usd is 0.0 until OAS cascade provides actual cost
           (see oas#393). Token counts are the primary data for now. *)
        (match trajectory_acc with
         | Some acc ->
           emit_cost_event ~masc_root:acc.masc_root
             ~agent_name:meta.name ~task_id:acc.task_id
             ~model ~input_tokens:input_tok ~output_tokens:output_tok
             ~cost_usd:0.0
         | None -> ());
        let text = Agent_sdk.Types.text_of_content response.content in
        let has_state_block =
          Option.is_some (Keeper_memory_policy.find_state_block text)
        in
        if not has_state_block && turn > 0 then
          Log.Keeper.debug
            "keeper:%s turn=%d state_block=absent (awaiting post-run synthesis)"
            meta.name turn;
        (try
           Sse.broadcast
             (`Assoc
               [
                 ("type", `String sse_turn_complete);
                 ("name", `String meta.name);
                 ("generation", `Int generation);
                 ("turn", `Int turn);
                 ("model_used", `String model);
                 ("input_tokens", `Int input_tok);
                 ("output_tokens", `Int output_tok);
                 ("has_state_block", `Bool has_state_block);
                 ("ts_unix", `Float (Unix.gettimeofday ()));
               ])
         with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ());
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
        let input_keys = match input with
          | `Assoc pairs -> String.concat "," (List.map fst pairs)
          | _ -> "-"
        in
        let outcome, out_len = match output with
          | Ok { Agent_sdk.Types.content; _ } -> "ok", String.length content
          | Error { Agent_sdk.Types.message; _ } -> "error", String.length message
        in
        Log.Keeper.info "keeper:%s tool_call tool=%s params=[%s] outcome=%s out_len=%d"
          (!meta_ref).name tool_name input_keys outcome out_len;
        (try on_tool_executed tool_name input output_text
         with Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
              Log.Keeper.error "keeper:%s on_tool_executed callback failed for %s: %s"
                (!meta_ref).name tool_name (Printexc.to_string exn));
        if List.mem tool_name board_write_tools then
          Log.Keeper.debug "keeper:%s social_event tool=%s"
            (!meta_ref).name tool_name;
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);

    pre_tool_use = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.PreToolUse { tool_name; input; accumulated_cost_usd; _ } ->
        let keeper_name = (!meta_ref).name in
        (* Safety gate 0: Keeper deny list *)
        if List.mem tool_name keeper_denied_tools then begin
          Log.Keeper.warn "keeper:%s deny list: blocked %s"
            keeper_name tool_name;
          broadcast_tool_skipped ~keeper_name ~tool_name ~reason_code:"keeper_deny";
          Agent_sdk.Hooks.Override
            (render_inline_skip_reason
               ~tool_name
               ~reason_code:"keeper_deny"
               ~reason_text:"tool is on the keeper deny list")
        end
        else
        (* Safety gate 1: Cost budget *)
        (match max_cost_usd with
         | Some limit when accumulated_cost_usd >= limit ->
           let reason_text =
             Printf.sprintf "accumulated_cost_usd=%.4f exceeded limit=%.4f"
               accumulated_cost_usd limit
           in
           Log.Keeper.warn "keeper:%s cost gate: $%.4f >= $%.4f limit, skipping %s"
             keeper_name accumulated_cost_usd limit tool_name;
           broadcast_tool_skipped ~keeper_name ~tool_name ~reason_code:"cost_gate";
           Agent_sdk.Hooks.Override
             (render_inline_skip_reason
                ~tool_name ~reason_code:"cost_gate" ~reason_text)
         | _ ->
           (* Safety gate 2: Destructive pattern detection *)
           if destructive_check && List.mem tool_name destructive_check_tools then
             let cmd = extract_command_from_input input in
             match Eval_gate.detect_destructive cmd with
             | Some (pattern, desc) ->
               let reason_text =
                 Printf.sprintf "pattern='%s' (%s)" pattern desc
               in
               Log.Keeper.warn "keeper:%s destructive pattern in %s: '%s' (%s)"
                 keeper_name tool_name pattern desc;
               broadcast_tool_skipped ~keeper_name ~tool_name
                 ~reason_code:"destructive_guard";
               Agent_sdk.Hooks.Override
                 (render_inline_skip_reason
                    ~tool_name ~reason_code:"destructive_guard" ~reason_text)
             | None -> Agent_sdk.Hooks.Continue
           else
             Agent_sdk.Hooks.Continue)
      | _ -> Agent_sdk.Hooks.Continue);

    on_idle = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.OnIdle { consecutive_idle_turns; tool_names; _ } ->
        let tools_str = match tool_names with
          | [] -> "<none>"
          | names -> String.concat ", " names
        in
        if consecutive_idle_turns >= 2 then begin
          Log.Keeper.warn "keeper:%s idle_turns=%d repeated_tools=[%s] — requesting stop (threshold=2, max_idle_turns=3)"
            (!meta_ref).name consecutive_idle_turns tools_str;
          Agent_sdk.Hooks.Skip
        end else begin
          Log.Keeper.info "keeper:%s idle_turns=%d tools=[%s] — nudging"
            (!meta_ref).name consecutive_idle_turns tools_str;
          Agent_sdk.Hooks.Nudge (Printf.sprintf "You are repeating the same tool calls (%s). Try a different approach: post to the Board, search memories, or interact with a peer keeper. Do not call %s again this turn." tools_str tools_str)
        end
      | _ -> Agent_sdk.Hooks.Continue);
  }

(** Static introspection of hook slot configuration.
    Returns a JSON summary of which hook slots are active, their gates/effects,
    and the deny list. Used by the dashboard to display hook status. *)
let hook_introspection_json
    ?(max_cost_usd : float option)
    ?(destructive_check : bool = true)
    ()
  : Yojson.Safe.t =
  let denied_json =
    `List (List.map (fun s -> `String s) keeper_denied_tools)
  in
  let destructive_json =
    `List (List.map (fun s -> `String s) destructive_check_tools)
  in
  `Assoc [
    ("slots", `Assoc [
      ("before_turn_params", `Assoc [
        ("active", `Bool true);
        ("source", `String "keeper_agent_run");
        ("features", `List [
          `String "dynamic_context";
          `String "bm25_progressive_disclosure";
        ]);
      ]);
      ("pre_tool_use", `Assoc [
        ("active", `Bool true);
        ("source", `String "keeper_hooks_oas");
        ("gates", `List [
          `String "keeper_deny_list";
          `String (if Option.is_some max_cost_usd
                   then "cost_budget" else "cost_budget_off");
          `String (if destructive_check
                   then "destructive_pattern" else "destructive_pattern_off");
        ]);
      ]);
      ("after_turn", `Assoc [
        ("active", `Bool true);
        ("source", `String "keeper_hooks_oas");
        ("effects", `List [
          `String "sse_broadcast";
          `String "cost_event";
          `String "metrics";
        ]);
      ]);
      ("post_tool_use", `Assoc [
        ("active", `Bool true);
        ("source", `String "keeper_hooks_oas");
        ("features", `List [
          `String "tool_callback";
          `String "board_write_detection";
        ]);
      ]);
      ("on_idle", `Assoc [
        ("active", `Bool true);
        ("source", `String "keeper_hooks_oas");
      ]);
    ]);
    ("deny_list", denied_json);
    ("deny_list_count", `Int (List.length keeper_denied_tools));
    ("destructive_check_tools", destructive_json);
    ("cost_budget",
      match max_cost_usd with
      | Some v ->
        `Assoc [("max_cost_usd", `Float v); ("active", `Bool true)]
      | None ->
        `Assoc [("active", `Bool false)]);
  ]
