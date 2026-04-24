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


(** Keeper deny list — derived from Tool_catalog surface SSOT.
    Administrative/destructive operations that should only be invoked
    by operators or through controlled workflows.
    Inspired by Trail of Bits' deny-rule pattern. *)
let keeper_denied_tools =
  Tool_catalog.tools_for_surface Tool_catalog.Keeper_denied

(* [escape_field], [render_inline_skip_reason], [broadcast_tool_skipped],
   and [extract_command_from_input] now live in [Keeper_guards]. They
   are used only by the decomposed pre_tool_use guard chain, so keeping
   them there avoids a circular dependency and concentrates the
   gate-level concerns in one module. *)

(** Derive a provider label from a model id.

    Benchmarking downstream (e.g. 15-keeper cascade weighted_random turns)
    needs to group costs.jsonl rows by provider. The raw [model] field
    mixes two conventions:
    - prefixed: [glm-coding:glm-5-turbo], [claude:claude-haiku-4-5-20251001]
    - bare: [glm-5-turbo], [claude-haiku-4-5-20251001] (emitted by some
      OAS transports that strip the scheme before reporting)

    Prefer the prefix when present; otherwise fall back to a minimal
    heuristic over known bare-name shapes. Returns [unknown] rather
    than guessing when no rule fits, so analysis queries can filter
    those rows out rather than miscount them. *)
let known_providers = [
  "glm-coding"; "glm"; "claude"; "claude_code";
  "gemini"; "gemini_cli"; "codex_cli"; "ollama";
]

let provider_of_model (model : string) : string =
  let bare_heuristic () =
    let starts_with prefix =
      String.length model >= String.length prefix
      && String.sub model 0 (String.length prefix) = prefix
    in
    if starts_with "glm-" then "glm-coding"
    else if starts_with "claude-" then "claude"
    else if starts_with "gemini-" then "gemini"
    else if starts_with "gpt-" then "openai"
    else if starts_with "qwen" || starts_with "llama" then "ollama"
    else "unknown"
  in
  match String.index_opt model ':' with
  | Some i ->
    let prefix = String.sub model 0 i in
    if List.mem prefix known_providers then prefix
    else bare_heuristic ()
  | None -> bare_heuristic ()

type tool_execution_summary =
  { tool_name : string
  ; provider : string
  ; outcome : string
  ; duration_ms : float
  }

let tool_execution_summary ~tool_name ~model ~success ~duration_ms :
    tool_execution_summary =
  { tool_name
  ; provider = provider_of_model model
  ; outcome = if success then "ok" else "error"
  ; duration_ms = max 0.0 duration_ms
  }

let record_keeper_tool_duration_metric
    ~(keeper_name : string)
    (summary : tool_execution_summary)
  : unit =
  Prometheus.observe_histogram
    Prometheus.metric_keeper_tool_call_duration
    ~labels:
      [ "keeper", keeper_name
      ; "provider", summary.provider
      ; "tool", summary.tool_name
      ; "outcome", summary.outcome
      ]
    (summary.duration_ms /. 1000.0)

(** Emit prompt/decode tokens-per-second histograms from an OAS turn
    response.  Safe to call with [telemetry = None] (no-op) and with
    positive [None] timing fields (per-metric no-op).  The histograms are
    labelled by [model], the coarse [provider] string derived from the
    model id, and the finer [provider_kind] reported by OAS.  Split from
    [masc_llm_inference_duration_seconds] because wall-clock latency
    mixes prefill and decode phases.

    Extracted so the after_turn hook is unit-testable without
    constructing a full [Oas.Hooks.AfterTurn] event. *)
let record_llm_tok_s_metrics
    ~(model : string)
    ~(telemetry : Oas.Types.inference_telemetry option)
  : unit =
  let prompt_tok_s_opt, decode_tok_s_opt =
    match telemetry with
    | Some { timings = Some t; _ } ->
      t.prompt_per_second, t.predicted_per_second
    | _ -> None, None
  in
  let provider_kind_label =
    match telemetry with
    | Some { provider_kind = Some pk; _ } ->
      Llm_provider.Provider_kind.to_string pk
    | _ -> "unknown"
  in
  let labels =
    [ "model", model
    ; "provider", provider_of_model model
    ; "provider_kind", provider_kind_label
    ]
  in
  (match prompt_tok_s_opt with
   | Some v when v > 0.0 ->
     Prometheus.observe_histogram
       Prometheus.metric_llm_prompt_tok_per_sec ~labels v
   | _ -> ());
  (match decode_tok_s_opt with
   | Some v when v > 0.0 ->
     Prometheus.observe_histogram
       Prometheus.metric_llm_decode_tok_per_sec ~labels v
   | _ -> ())

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
    ?(telemetry : Oas.Types.inference_telemetry option)
    () : unit =
  let path = Filename.concat masc_root "costs.jsonl" in
  let int_field name = function
    | Some n -> [ (name, `Int n) ]
    | None -> []
  in
  let float_field name = function
    | Some v -> [ (name, `Float v) ]
    | None -> []
  in
  let telemetry_fields = match telemetry with
    | Some t ->
      int_field "reasoning_tokens" t.reasoning_tokens
      @ (match t.timings with
         | Some tm ->
           int_field "cache_n" tm.cache_n
           @ float_field "prompt_per_second" tm.prompt_per_second
           @ float_field "provider_tokens_per_second" tm.predicted_per_second
           @ float_field "hw_decode_tokens_per_second" tm.predicted_per_second
         | None -> [])
      @ float_field "peak_memory_gb" t.peak_memory_gb
      @ [("request_latency_ms", `Int t.request_latency_ms)]
    | None -> []
  in
  let entry = `Assoc ([
    ("agent", `String agent_name);
    ("task_id", Json_util.string_opt_to_json task_id);
    ("provider", `String (provider_of_model model));
    ("model", `String model);
    ("input_tokens", `Int input_tokens);
    ("output_tokens", `Int output_tokens);
    ("cost_usd", `Float cost_usd);
    ("timestamp", `String (Types.now_iso ()));
    ("source", `String "auto_trajectory");
  ] @ telemetry_fields) in
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

    @param meta_ref Mutable ref to keeper metadata
    @param generation Current generation counter
    @param max_cost_usd Optional cost budget (rejects tool calls above limit)
    @param destructive_check Enable destructive pattern detection (default true)
    @param pre_tool_use_guard Optional callback that can short-circuit a tool
           before execution by returning an inline override response.
    @param on_tool_executed Optional callback after each tool execution
    @param trajectory_acc Optional trajectory accumulator for cost attribution

    Issue #8597 #3-5: dropped [~config], [~session], [~ctx_snapshot]. The
    closure body never read them; the docstring even admitted [ctx_snapshot]
    was "reserved, unused". State now flows through [meta_ref] (mutable) and
    the explicit callbacks (pre_tool_use_guard / on_tool_executed). *)

(** Suggest alternative tools from the keeper's allowed set that were
    NOT part of the repeated tool calls. Returns up to [max_suggestions]
    tool names, deterministically selected from the allowed set.
    This is the deterministic envelope: gathering candidates from a
    known set. The LLM (non-deterministic) decides which to use. *)
let suggest_alternatives ~(allowed_tools : string list)
    ~(repeated_tools : string list) ~(max_suggestions : int) : string list =
  let module SS = Set.Make (String) in
  let repeated_set =
    List.fold_left (fun acc t -> SS.add t acc) SS.empty repeated_tools
  in
  allowed_tools
  |> List.filter (fun t ->
       not (SS.mem t repeated_set)
       && t <> Tool_name.Keeper.to_string Tool_name.Keeper.Stay_silent)
  |> fun candidates ->
     let len = List.length candidates in
     if len <= max_suggestions then candidates
     else List.filteri (fun i _ -> i < max_suggestions) candidates

(** Pure decision logic for the on_idle hook.  Testable without Coord.config.

    Graduated response to repeated tool calls uses the configured
    [Env_config_keeper.KeeperKeepalive.idle_skip_threshold]:
    - For idle counts below [skip_at - 1]: gentle nudge suggesting alternatives
    - For idle counts at [skip_at - 1]: final warning (stronger nudge)
      suggesting [stay_silent]
    - For idle counts at or above [skip_at]: Skip (end this turn, but the
      heartbeat loop will retry next cycle)

    The [~allowed_tools] parameter enables concrete alternative suggestions
    instead of generic "try a different tool" messages. This is the
    deterministic envelope providing structured options for the
    non-deterministic LLM to choose from.

    Skip is not death. The keeper's heartbeat loop will schedule a new
    turn on the next cycle with fresh context. The key insight is that
    burning more tokens on a stuck LLM is worse than retrying later. *)
let on_idle_decision_with_threshold ~skip_at ~consecutive_idle_turns
    ~allowed_tools ~tool_names
  : Oas.Hooks.hook_decision =
  let tools_str = match tool_names with
    | [] -> "<none>"
    | names -> String.concat ", " names
  in
  let alternatives =
    suggest_alternatives ~allowed_tools ~repeated_tools:tool_names
      ~max_suggestions:5
  in
  let alt_str = match alternatives with
    | [] -> "keeper_tool_search, keeper_board_post, or stay_silent"
    | alts -> String.concat ", " alts
  in
  if consecutive_idle_turns >= skip_at then
    Oas.Hooks.Skip
  else if consecutive_idle_turns = skip_at - 1 then
    Oas.Hooks.Nudge
      (Printf.sprintf
         "FINAL WARNING: you repeated %s %d times. Next idle = turn ends. \
          Use one of these instead: %s — or call keeper_stay_silent to do nothing."
         tools_str consecutive_idle_turns alt_str)
  else
    Oas.Hooks.Nudge
      (Printf.sprintf
         "You are repeating %s without progress. \
          Available alternatives: %s."
         tools_str alt_str)

(** Wrapper around {!on_idle_decision_with_threshold} that supplies the
    [idle_skip_threshold] constant from [Env_config_keeper.KeeperKeepalive].
    Reads the keeper's allowed tool names from [meta_ref] for concrete
    alternative suggestions. *)
let on_idle_decision ~consecutive_idle_turns ~allowed_tools ~tool_names
  : Oas.Hooks.hook_decision =
  let skip_at = Env_config_keeper.KeeperKeepalive.idle_skip_threshold in
  on_idle_decision_with_threshold ~skip_at ~consecutive_idle_turns
    ~allowed_tools ~tool_names

let recent_tool_streak_count ?(within_sec = 900.0) ~(tool_name : string)
    (entries : Yojson.Safe.t list) : int =
  let now = Time_compat.now () in
  let rec loop count = function
    | [] -> count
    | entry :: rest ->
      (match Safe_ops.json_string_opt "tool" entry,
              Safe_ops.json_float_opt "ts" entry with
       | Some logged_tool, Some ts
         when String.equal logged_tool tool_name && now -. ts <= within_sec ->
           loop (count + 1) rest
       | _ -> count)
  in
  loop 0 (List.rev entries)

let make_hooks
    ~(meta_ref : Keeper_types.keeper_meta ref)
    ~(generation : int)
    ?(max_cost_usd : float option)
    ?(destructive_check : bool = true)
    ?(pre_tool_use_guard :
        tool_name:string -> input:Yojson.Safe.t -> string option =
        fun ~tool_name:_ ~input:_ -> None)
    ?(on_tool_executed :
        tool_name:string -> input:Yojson.Safe.t -> output_text:string ->
        success:bool -> duration_ms:float -> provider:string -> unit =
        fun ~tool_name:_ ~input:_ ~output_text:_ ~success:_ ~duration_ms:_ ~provider:_ -> ())
    ?(trajectory_acc : Trajectory.accumulator option)
    ?(discover_work_nudge : unit -> string option =
        fun () -> None)
    ()
  : Oas.Hooks.hooks =
  let sse_turn_complete = "keeper_turn_complete" in
  let board_write_tools =
    [ "keeper_board_post"; "keeper_board_comment"; "keeper_board_vote" ]
  in
  let tool_start_time = ref 0.0 in
  (* Per-turn tool call counter for SSE enrichment.
     Incremented in post_tool_use, reset in after_turn. *)
  let tool_call_count_ref = ref 0 in
  (* Streak gate state: tracks consecutive calls to the same tool
     name (regardless of args). Lives across invocations via the
     [make_hooks] closure — one state per keeper. *)
  let streak_state = Keeper_guards.make_streak_state () in
  let streak_threshold = 5 in
  (* Build the pre_tool_use guard chain via Hooks.compose. Each guard
     lives in Keeper_guards and emits its own masc:keeper_gate event
     on override/approval decisions. *)
  let guard_chain =
    Keeper_guards.build_chain
      ~meta_ref
      ~tool_start_time
      ~streak_state
      ~streak_threshold
      ~denied:keeper_denied_tools
      ~max_cost_usd
      ~destructive_check
      ~pre_tool_use_guard
  in
  let non_gate_hooks =
    { Oas.Hooks.empty with

    (* Work discovery injection (#8773 fix). The callback owns the policy
       (interval, sources, query) and returns Some text only when there
       is actionable work to surface. Hook stays domain-agnostic: it just
       wraps the callback's payload in a Nudge so the next LLM turn sees
       it as ambient observation. Returns Continue when callback yields
       None — silent no-op, no token cost. *)
    before_turn = Some (fun event ->
      match event with
      | Oas.Hooks.BeforeTurn _ ->
        (match discover_work_nudge () with
         | None -> Oas.Hooks.Continue
         | Some text when String.trim text = "" ->
           Oas.Hooks.Continue
         | Some text when not (String.is_valid_utf_8 text) ->
           (* Defensive: nudge path producers (e.g. keeper_agent_run's
              discover_work_nudge) source strings from external input
              (task titles, operator guidance, board posts). A byte-
              level truncation upstream can leave an orphan UTF-8
              continuation byte, and codex CLI rejects the resulting
              argv with "invalid UTF-8 was detected in one or more
              arguments" at parse time (non-cascadable). This gate
              prevents polluted nudges from ever reaching transport
              argv, regardless of which producer introduced the
              drift. See #9036 for the first observed producer fix. *)
           Log.Keeper.warn "keeper:%s before_turn: dropped invalid UTF-8 nudge (%d bytes)"
             (!meta_ref).name (String.length text);
           Oas.Hooks.Continue
         | Some text ->
           Log.Keeper.info "keeper:%s before_turn: injecting work_discovery nudge (%d chars)"
             (!meta_ref).name (String.length text);
           Oas.Hooks.Nudge text)
      | _ -> Oas.Hooks.Continue);

    after_turn = Some (fun event ->
      match event with
      | Oas.Hooks.AfterTurn { turn; response } ->
        let meta = !meta_ref in
        let model = response.model in
        let input_tok, output_tok, turn_cost_usd = match response.usage with
          | Some u -> (u.input_tokens, u.output_tokens,
                       Option.value ~default:0.0 u.cost_usd)
          | None -> (0, 0, 0.0)
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
        (* Inference latency histogram for /metrics endpoint.
           Split observations into three buckets so we can tell "metric is
           silent because no telemetry" apart from "metric is silent because
           the hook isn't running". Without this split a histogram sum/count
           of 0 is ambiguous between the two. *)
        Prometheus.inc_counter
          "masc_after_turn_hook_total"
          ~labels:[("model", model)] ();
        (match response.telemetry with
         | Some t when t.request_latency_ms > 0 ->
           Prometheus.observe_histogram
             "masc_llm_inference_duration_seconds"
             ~labels:[("model", model)]
             (Float.of_int t.request_latency_ms /. 1000.0)
         | Some _ ->
           Prometheus.inc_counter
             "masc_after_turn_telemetry_zero_latency_total"
             ~labels:[("model", model)] ()
         | None ->
           Prometheus.inc_counter
             "masc_after_turn_telemetry_missing_total"
             ~labels:[("model", model)] ());
        let fmt_tok_s = function
          | Some v -> Printf.sprintf "%.1f" v
          | None -> "-"
        in
        (* Capture each telemetry projection independently.  Anthropic and
           Gemini populate [request_latency_ms] (patched in OAS api.ml) but
           leave [timings = None]; the previous single-match folded those
           three fields together and surfaced [latency_ms=0] whenever tok/s
           were missing, which hid Anthropic/Gemini latency on the log line
           and in downstream dashboards. *)
        let prompt_tok_s_opt, decode_tok_s_opt =
          match response.telemetry with
          | Some { timings = Some t; _ } ->
              t.prompt_per_second, t.predicted_per_second
          | _ -> None, None
        in
        let latency_ms =
          match response.telemetry with
          | Some t -> t.request_latency_ms
          | None -> 0
        in
        record_llm_tok_s_metrics ~model ~telemetry:response.telemetry;
        let prompt_tok_s = fmt_tok_s prompt_tok_s_opt in
        let decode_tok_s = fmt_tok_s decode_tok_s_opt in
        Log.Keeper.info
          "keeper:%s turn=%d total_turns=%d model=%s tokens=%d prompt_tok_s=%s decode_tok_s=%s latency_ms=%d"
          meta.name turn meta.runtime.usage.total_turns model total_tok
          prompt_tok_s decode_tok_s latency_ms;
        (* Emit per-turn cost event for task attribution.
           cost_usd from OAS Pricing.annotate_response_cost (oas#393 resolved). *)
        (match trajectory_acc with
         | Some acc ->
           emit_cost_event ~masc_root:acc.masc_root
             ~agent_name:meta.name ~task_id:acc.task_id
             ~model ~input_tokens:input_tok ~output_tokens:output_tok
             ~cost_usd:turn_cost_usd ?telemetry:response.telemetry ()
         | None -> ());
        let text = Oas.Types.text_of_content response.content in
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
                 ("cost_usd", `Float turn_cost_usd);
                 ("tool_calls_made", `Int !tool_call_count_ref);
                 ("total_turns", `Int meta.runtime.usage.total_turns);
                 ("ts_unix", `Float (Unix.gettimeofday ()));
               ])
         with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ());
        (* Reset same-name streak at turn boundary so it doesn't
           carry across turns (e.g., 4 calls in turn N + 1 in turn N+1
           should not hit threshold 5). *)
        streak_state.Keeper_guards.entry <- ("", 0);
        tool_call_count_ref := 0;
        Oas.Hooks.Continue
      | _ -> Oas.Hooks.Continue);

    post_tool_use = Some (fun event ->
      match event with
      | Oas.Hooks.PostToolUse { tool_name; input; output; duration_ms = hook_duration_ms; _ } ->
        incr tool_call_count_ref;
        let output_text = match output with
          | Ok { Oas.Types.content; _ } -> content
          | Error { Oas.Types.message; _ } -> message
        in
        let input_keys = match input with
          | `Assoc pairs -> String.concat "," (List.map fst pairs)
          | _ -> "-"
        in
        let outcome, out_len = match output with
          | Ok { Oas.Types.content; _ } -> "ok", String.length content
          | Error { Oas.Types.message; _ } -> "error", String.length message
        in
        Log.Keeper.info "keeper:%s tool_call tool=%s params=[%s] outcome=%s out_len=%d"
          (!meta_ref).name tool_name input_keys outcome out_len;
        (* Persistent tool call I/O log for dashboard inspector.
           tool_start_time is keeper-local (one ref per make_hooks call).
           Tool calls within Agent.run are sequential, so no race. *)
        let duration_ms =
          if hook_duration_ms > 0.0
          then hook_duration_ms
          else (Time_compat.now () -. !tool_start_time) *. 1000.0
        in
        let model =
          let m = (!meta_ref).runtime.usage.last_model_used in
          if m = "" then (!meta_ref).cascade_name else m
        in
        let summary =
          tool_execution_summary
            ~tool_name
            ~model
            ~success:(outcome = "ok")
            ~duration_ms
        in
        record_keeper_tool_duration_metric
          ~keeper_name:(!meta_ref).name
          summary;
        (* Consume truncation info set by keeper_tools_oas before returning
           the (possibly truncated) result to OAS. Falls back to out_len
           when no truncation info was set (e.g. OAS-internal tool calls). *)
        let (original_bytes, truncated_to) =
          Keeper_tool_call_log.consume_truncation_info
            ~keeper_name:(!meta_ref).name ()
        in
        let result_bytes = if original_bytes > 0 then original_bytes else out_len in
        let ( lane
            , tool_choice
            , thinking_enabled
            , thinking_budget
            , prompt_fingerprint
            , trace_id
            , session_id
            , turn
            , keeper_turn_id
            , task_id
            , goal_ids
            , sandbox_profile
            , network_mode
            , shared_memory_scope
            , approval_mode ) =
          Keeper_tool_call_log.get_turn_context
            ~keeper_name:(!meta_ref).name ()
        in
        (try
           Keeper_tool_call_log.log_call
             ~keeper_name:(!meta_ref).name
             ~tool_name ~input ~output_text
             ~success:(outcome = "ok") ~duration_ms
             ~model:(let m = (!meta_ref).runtime.usage.last_model_used in
                     if m = "" then (!meta_ref).cascade_name else m)
             ?lane ?tool_choice ?thinking_enabled ?thinking_budget
             ?prompt_fingerprint
             ?trace_id ?session_id ?turn ?keeper_turn_id ?task_id ?goal_ids
             ?sandbox_profile ?network_mode
             ?shared_memory_scope ?approval_mode
             ~result_bytes ?truncated_to ()
         with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ());
        (try
           on_tool_executed
             ~tool_name
             ~input
             ~output_text
             ~success:(outcome = "ok")
             ~duration_ms:summary.duration_ms
             ~provider:summary.provider
         with Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
              Log.Keeper.error "keeper:%s on_tool_executed callback failed for %s: %s"
                (!meta_ref).name tool_name (Printexc.to_string exn));
        if List.mem tool_name board_write_tools then
          Log.Keeper.debug "keeper:%s social_event tool=%s"
            (!meta_ref).name tool_name;
        Oas.Hooks.Continue
      | _ -> Oas.Hooks.Continue);

    (* pre_tool_use is provided by [guard_chain] below via Hooks.compose.
       The guard chain (timing + custom + streak + deny + cost +
       destructive + governance_approval) is composed with these
       non-gate hooks at the end of [make_hooks]. *)

    on_idle = Some (fun event ->
      match event with
      | Oas.Hooks.OnIdle { consecutive_idle_turns; tool_names; _ } ->
        let allowed_tools =
          Keeper_tool_policy.keeper_allowed_tool_names !meta_ref in
        let decision =
          on_idle_decision ~consecutive_idle_turns ~tool_names
            ~allowed_tools in
        let tools_str = match tool_names with
          | [] -> "<none>" | names -> String.concat ", " names in
        (match decision with
         | Oas.Hooks.Skip ->
           Log.Keeper.warn "keeper:%s idle_turns=%d repeated_tools=[%s] — requesting stop"
             (!meta_ref).name consecutive_idle_turns tools_str
         | Oas.Hooks.Nudge _ ->
           Log.Keeper.info "keeper:%s idle_turns=%d tools=[%s] — nudging LLM via Nudge"
             (!meta_ref).name consecutive_idle_turns tools_str
         | _ -> ());
        decision
      | _ -> Oas.Hooks.Continue);

    on_error = Some (function
      | Oas.Hooks.OnError { detail; context = err_ctx } ->
        Log.Keeper.error "keeper:%s on_error: %s (context: %s)"
          (!meta_ref).name detail err_ctx;
        Oas.Hooks.Continue
      | _ -> Oas.Hooks.Continue);

    on_tool_error = Some (function
      | Oas.Hooks.OnToolError { tool_name; error } ->
        Log.Keeper.error "keeper:%s tool_error: %s — %s"
          (!meta_ref).name tool_name error;
        Oas.Hooks.Continue
      | _ -> Oas.Hooks.Continue);

    post_tool_use_failure = Some (function
      | Oas.Hooks.PostToolUseFailure { tool_name; error; _ } ->
        let meta = !meta_ref in
        (* The richer counterpart
             "tool <name> returned error result (n/max): <detail>"
           is already emitted at ERROR by keeper_tools_oas before this hook
           runs. Emitting a second ERROR here with the same error content
           produces paired duplicate lines per tool failure. Keep a debug
           trace for hook-chain readers; the metric below still records. *)
        Log.Keeper.debug "keeper:%s tool_use_failure: %s — %s"
          meta.name tool_name error;
        Heuristic_metrics.record {
          module_name = "keeper_hooks_oas";
          site = "post_tool_use_failure";
          raw_value = 1.0;
          threshold = 0.0;
          triggered = true;
          provenance = Pipeline_stage "post_tool_use_failure";
          timestamp = Unix.gettimeofday ();
        };
        Oas.Hooks.Continue
      | _ -> Oas.Hooks.Continue);
  }
  in
  (* Guards fire first (outer). If all return Continue, non_gate_hooks
     fire for the remaining slots (inner). pre_tool_use lives in
     guard_chain only; non_gate_hooks has it None, so Hooks.compose
     keeps guard_chain's pre_tool_use verbatim. *)
  Oas.Hooks.compose ~outer:guard_chain ~inner:non_gate_hooks

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
    `String "dynamic_boundary (Tool_dispatch.is_destructive)"
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
      ("on_error", `Assoc [
        ("active", `Bool true);
        ("source", `String "keeper_hooks_oas");
      ]);
      ("on_tool_error", `Assoc [
        ("active", `Bool true);
        ("source", `String "keeper_hooks_oas");
      ]);
      ("post_tool_use_failure", `Assoc [
        ("active", `Bool true);
        ("source", `String "keeper_hooks_oas");
        ("effects", `List [
          `String "heuristic_metrics";
        ]);
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
