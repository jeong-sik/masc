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
  [ "keeper_bash"; "keeper_fs_edit"; "keeper_edit"; "keeper_github" ]

(** Keeper deny list — derived from Tool_catalog surface SSOT.
    Administrative/destructive operations that should only be invoked
    by operators or through controlled workflows.
    Inspired by Trail of Bits' deny-rule pattern. *)
let keeper_denied_tools =
  Tool_catalog.tools_for_surface Tool_catalog.Keeper_denied

type skip_reason = {
  tool_name : string;
  source : string;
  reason_code : string;
  reason_text : string;
  skipped_at_unix : float;
}

let recent_skip_reasons : (string, skip_reason) Hashtbl.t = Hashtbl.create 16
let recent_skip_reasons_mu = Eio.Mutex.create ()

let with_skip_rw f = Eio_guard.with_mutex recent_skip_reasons_mu f

let clear_skip_reason keeper_name =
  with_skip_rw (fun () -> Hashtbl.remove recent_skip_reasons keeper_name)

let record_skip_reason ~keeper_name ~tool_name ~source ~reason_code ~reason_text =
  let reason =
    {
      tool_name;
      source;
      reason_code;
      reason_text;
      skipped_at_unix = Unix.gettimeofday ();
    }
  in
  with_skip_rw (fun () -> Hashtbl.replace recent_skip_reasons keeper_name reason)

let consume_skip_reason keeper_name =
  with_skip_rw (fun () ->
      match Hashtbl.find_opt recent_skip_reasons keeper_name with
      | None -> None
      | Some reason ->
          Hashtbl.remove recent_skip_reasons keeper_name;
          Some reason)

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
    ("task_id",
      (match task_id with Some t -> `String t | None -> `Null));
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
    ~(config : Room.config)
    ~(meta_ref : Keeper_types.keeper_meta ref)
    ~(session : Keeper_working_context.session_context)
    ~(ctx_ref : Keeper_working_context.working_context ref)
    ~(generation : int)
    ?(max_cost_usd : float option)
    ?(destructive_check : bool = true)
    ?(on_tool_executed : string -> Yojson.Safe.t -> string -> unit =
        fun _ _ _ -> ())
    ?(trajectory_acc : Trajectory.accumulator option)
    ()
  : Agent_sdk.Hooks.hooks =
  ignore config;
  ignore session;
  ignore ctx_ref;
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
        on_tool_executed tool_name input output_text;
        if List.mem tool_name board_write_tools then
          Log.Keeper.info "keeper:%s social_event tool=%s"
            (!meta_ref).name tool_name;
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);

    pre_tool_use = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.PreToolUse { tool_name; input; accumulated_cost_usd; _ } ->
        let keeper_name = (!meta_ref).name in
        (* Safety gate 0: Keeper deny list *)
        if List.mem tool_name keeper_denied_tools then begin
          record_skip_reason
            ~keeper_name
            ~tool_name
            ~source:"keeper_hook"
            ~reason_code:"keeper_deny"
            ~reason_text:"tool is on the keeper deny list";
          Log.Keeper.warn "keeper:%s deny list: blocked %s"
            keeper_name tool_name;
          Agent_sdk.Hooks.Skip
        end
        else
        (* Safety gate 1: Cost budget *)
        (match max_cost_usd with
         | Some limit when accumulated_cost_usd >= limit ->
           record_skip_reason
             ~keeper_name
             ~tool_name
             ~source:"keeper_hook"
             ~reason_code:"cost_gate"
             ~reason_text:
               (Printf.sprintf
                  "accumulated_cost_usd=%.4f exceeded limit=%.4f"
                  accumulated_cost_usd limit);
           Log.Keeper.warn "keeper:%s cost gate: $%.4f >= $%.4f limit, skipping %s"
             keeper_name accumulated_cost_usd limit tool_name;
           Agent_sdk.Hooks.Skip
         | _ ->
           (* Safety gate 2: Destructive pattern detection *)
           if destructive_check && List.mem tool_name destructive_check_tools then
             let cmd = extract_command_from_input input in
             match Eval_gate.detect_destructive cmd with
             | Some (pattern, desc) ->
               record_skip_reason
                 ~keeper_name
                 ~tool_name
                 ~source:"keeper_hook"
                 ~reason_code:"destructive_guard"
                 ~reason_text:
                   (Printf.sprintf "pattern='%s' (%s)" pattern desc);
               Log.Keeper.warn "keeper:%s destructive pattern in %s: '%s' (%s)"
                 keeper_name tool_name pattern desc;
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
