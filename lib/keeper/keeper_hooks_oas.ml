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


(** Shared type/helper module (intra-library file split, 2026-05-16).
    Hoisted to the top so the rest of this module can refer to its
    bindings — see classify_usage_trust which calls
    [context_max_of_telemetry]. *)
include Keeper_hooks_oas_types

(** Keeper deny list — derived from Tool_catalog surface SSOT.
    Administrative/destructive operations that should only be invoked
    by operators or through controlled workflows.
    Inspired by Trail of Bits' deny-rule pattern. *)
let keeper_denied_tools =
  Tool_catalog.tools_for_surface Tool_catalog.Keeper_denied

(* label_* string constants moved to Keeper_hooks_oas_types
   (intra-library file split, 2026-05-16). *)
(* callback_label_* constants moved to Keeper_hooks_oas_types
   (intra-library file split, 2026-05-16). *)
(* outcome_ok / outcome_error already moved to Keeper_hooks_oas_types in
   step 5; this duplicate block was left behind by accident and is now
   cleaned up. *)


(* [escape_field], [render_inline_skip_reason], [broadcast_tool_skipped],
   and [extract_command_from_input] now live in [Keeper_guards]. They
   are used only by the decomposed pre_tool_use guard chain, so keeping
   them there avoids a circular dependency and concentrates the
   gate-level concerns in one module. *)

(** Keeper-facing telemetry uses a neutral runtime lane.  Concrete
    provider/model identity belongs to OAS and lower-level cascade adapters. *)
let runtime_lane_label = "runtime"

let runtime_lane_of_model (_model : string) : string = runtime_lane_label

(* Inference telemetry redaction moved to Keeper_hooks_oas_types
   (intra-library file split, 2026-05-16). *)

(* usage_has_tokens / is_keeper_board_write_tool_name / current_keeper_model
   / stop_reason_label_* moved to Keeper_hooks_oas_types (intra-library
   file split, 2026-05-16). *)

let stop_reason_to_label = function
  | Agent_sdk.Types.EndTurn -> stop_reason_label_end_turn
  | Agent_sdk.Types.StopToolUse -> stop_reason_label_tool_use
  | Agent_sdk.Types.MaxTokens -> stop_reason_label_max_tokens
  | Agent_sdk.Types.StopSequence -> stop_reason_label_stop_sequence
  | Agent_sdk.Types.Unknown _ -> stop_reason_label_unknown

let idle_severity_to_label = function
  | Agent_sdk.Hooks.Idle_severity.Nudge -> "nudge"
  | Agent_sdk.Hooks.Idle_severity.Final_warning -> "final_warning"
  | Agent_sdk.Hooks.Idle_severity.Skip -> "skip"

let idle_decision_to_label = function
  | Agent_sdk.Hooks.Continue -> "continue"
  | Agent_sdk.Hooks.Skip -> "skip"
  | Agent_sdk.Hooks.Nudge _ -> "nudge"
  | Agent_sdk.Hooks.Override _ -> "override"
  | Agent_sdk.Hooks.ApprovalRequired -> "approval_required"
  | Agent_sdk.Hooks.AdjustParams _ -> "adjust_params"
  | Agent_sdk.Hooks.ElicitInput _ -> "elicit_input"

let tool_error_is_workflow_rejection error =
  try
    let json = Yojson.Safe.from_string error in
    let direct = Safe_ops.json_string_opt "failure_class" json in
    let nested =
      match Yojson.Safe.Util.member "detail" json with
      | `Assoc _ as detail -> Safe_ops.json_string_opt "failure_class" detail
      | _ -> None
    in
    match Option.value direct ~default:(Option.value nested ~default:"") with
    | "workflow_rejection" -> true
    | _ -> false
  with
  | _ -> false

module Gate_attempt = Keeper_hooks_oas_gate_attempt

let render_pre_tool_gate_output = Gate_attempt.render_pre_tool_gate_output
let pre_tool_gate_error = Gate_attempt.pre_tool_gate_error
let trajectory_duration_ms = Gate_attempt.trajectory_duration_ms
let record_pre_tool_gate_attempt = Gate_attempt.record_pre_tool_gate_attempt

include Keeper_hooks_oas_response_metrics

(* cost_status / thinking_log_summary / pr_action types + telemetry helpers
   moved to Keeper_hooks_oas_types (intra-library file split, 2026-05-16).
   The include is hoisted to the top of this module — see the comment
   near the keeper deny-list definition. *)

(* cost_source_unmetered_provider / cost_source_computed / oas_reported_cost
   moved to Keeper_hooks_oas_types (intra-library file split, 2026-05-16). *)

(* type tool_execution_summary + builder moved to Keeper_hooks_oas_types
   (intra-library file split, 2026-05-16). *)

(** #10318: classify why [cost_usd] ended up as it did so the
    ledger entry is self-describing.  Pre-fix [costs.jsonl] showed
    100% [cost_usd=0] across 1697 entries with no way to tell
    "untrusted usage zeroed it" apart from "pricing catalog miss"
    apart from "free local provider".  Each silent path collapsed
    to the same [0.0] field and the operator could only see
    "tracking is broken" without the next concrete action.

    Bounded source values:
    - [computed]              — cost > 0 reported by OAS.
    - [missing_usage]         — no usage payload from the provider.
    - [untrusted_usage]       — usage_trust gate suppressed the value.
    - [unmetered_provider]    — OAS/runtime explicitly marks the call free.
    - [oas_cost_unreported]   — OAS returned tokens but no positive cost.
    - [zero_token_call]       — trusted but tokens=0
                                (tool-only call or empty completion). *)
include Keeper_hooks_oas_cost_events

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

include Keeper_hooks_oas_idle

(* pr_review_action_metric_event / pr_work_action_metric_event /
   normalize_pr_review_action moved to Keeper_hooks_oas_types
   (intra-library file split, 2026-05-16). *)

include Keeper_hooks_oas_pr_metrics

let make_hooks
    ~(config : Coord.config)
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
    ?(passive_loop_nudge : unit -> string option =
        fun () -> None)
    ()
  : Agent_sdk.Hooks.hooks =
  let sse_turn_complete = "keeper_turn_complete" in
  let tool_start_time = ref 0.0 in
  (* Per-turn tool call counter for SSE enrichment.
     Incremented in post_tool_use, reset in after_turn. *)
  let tool_call_count_ref = ref 0 in
  let record_progress event_kind =
    Keeper_registry.record_turn_progress
      ~base_path:config.base_path
      (!meta_ref).name
      ~event_kind
  in
  (* Streak gate state: tracks consecutive calls to the same tool
     name (regardless of args). Lives across invocations via the
     [make_hooks] closure — one state per keeper. *)
  let streak_state = Keeper_guards.make_streak_state () in
  let streak_threshold = 5 in
  let record_gate_decision event =
    record_pre_tool_gate_attempt
      ~meta_ref
      ~tool_call_count_ref
      ?trajectory_acc
      event
  in
  (* Build the pre_tool_use guard chain via Hooks.compose. Each guard
     lives in Keeper_guards and emits its own masc:keeper_gate event
     on override/approval decisions. The observer persists the same
     attempted action into tool-call and trajectory lanes so blocked
     pre-tool attempts are not invisible to tool-stats. *)
  let guard_chain =
    Keeper_guards.build_chain
      ~meta_ref
      ~tool_start_time
      ~streak_state
      ~streak_threshold
      ~denied:keeper_denied_tools
      ~max_cost_usd
      ~destructive_check
      ~on_gate_decision:record_gate_decision
      ~pre_tool_use_guard
  in
  let non_gate_hooks =
    { Agent_sdk.Hooks.empty with

    (* Work discovery injection (#8773 fix) and passive loop action injection
       (#12799 P1/5). The callbacks own their policy and return Some text only
       when there is actionable content to surface. The passive loop nudge
       takes priority (prepended) when active, since it requires immediate
       action. Hook stays domain-agnostic: it wraps payloads in a Nudge so
       the next LLM turn sees them as ambient observation. Returns Continue
       when both callbacks yield None — silent no-op, no token cost. *)
    before_turn = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.BeforeTurn _ ->
        record_progress "sdk_before_turn";
        let loop_alert = passive_loop_nudge () in
        let work_text = discover_work_nudge () in
        let combined_with_source =
          match loop_alert, work_text with
          | None, None -> None
          | Some a, None -> Some (a, "passive_loop_nudge")
          | None, Some w -> Some (w, "work_discovery")
          | Some a, Some w ->
            Some (a ^ "\n\n" ^ w, "passive_loop_nudge + work_discovery")
        in
        (match combined_with_source with
         | None -> Agent_sdk.Hooks.Continue
         | Some (text, _) when String.trim text = "" ->
           Agent_sdk.Hooks.Continue
         | Some (text, _) when not (String.is_valid_utf_8 text) ->
           (* Defensive: nudge path producers source strings from external
              input (task titles, operator guidance, board posts). A byte-
              level truncation upstream can leave an orphan UTF-8 continuation
              byte, and codex CLI rejects the resulting argv with "invalid
              UTF-8 was detected in one or more arguments" at parse time
              (non-cascadable). This gate prevents polluted nudges from ever
              reaching transport argv, regardless of which producer introduced
              the drift. See #9036 for the first observed producer fix. *)
           Log.Keeper.warn "keeper:%s before_turn: dropped invalid UTF-8 nudge (%d bytes)"
             (!meta_ref).name (String.length text);
           Agent_sdk.Hooks.Continue
         | Some (text, source) ->
           Log.Keeper.info "keeper:%s before_turn: injecting %s (%d chars)"
             (!meta_ref).name source (String.length text);
           Agent_sdk.Hooks.Nudge text)
      | _ -> Agent_sdk.Hooks.Continue);

    after_turn = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.AfterTurn { turn; response } ->
        record_progress "sdk_after_turn";
        let meta = !meta_ref in
        let model = resolve_after_turn_model ~keeper_name:meta.name ~response in
        let usage_trust =
          classify_usage_trust ?usage:response.usage ~model
            ~telemetry:response.telemetry ()
        in
        let usage_trusted = Keeper_usage_trust.is_trusted usage_trust in
        record_usage_anomaly_metrics ~keeper_name:meta.name ~model usage_trust;
        let raw_input_tok, raw_output_tok =
          match response.usage with
          | Some u -> u.input_tokens, u.output_tokens
          | None -> 0, 0
        in
        let input_tok, output_tok, turn_cost_usd, usage_missing =
          match response.usage with
          | Some u when usage_trusted ->
              ( u.input_tokens,
                u.output_tokens,
                oas_reported_cost u,
                false )
          | Some _ -> (0, 0, 0.0, false)
          | None -> (0, 0, 0.0, true)
        in
        let cost_usd_for_event =
          if usage_trusted then turn_cost_usd
          else
            match response.usage with
            | Some { cost_usd = Some cost; _ } when cost > 0.0 -> cost
            | Some _ | None -> 0.0
        in
        let total_tok = input_tok + output_tok in
        if (not usage_missing) && not usage_trusted then (
          let reasons =
            match Keeper_usage_trust.reasons usage_trust with
            | [] -> [Keeper_usage_trust.to_string usage_trust]
            | reasons -> reasons
          in
          if Keeper_usage_trust.warns_operator usage_trust then
            Log.Keeper.warn
              "keeper:%s after_turn usage telemetry untrusted runtime_lane=%s reasons=%s input=%d output=%d context_max=%d"
              meta.name runtime_lane_label
              (String.concat "," reasons)
              raw_input_tok raw_output_tok
              (context_max_of_telemetry response.telemetry)
          else
            Log.Keeper.info
              "keeper:%s after_turn usage telemetry unavailable runtime_lane=%s reasons=%s input=%d output=%d context_max=%d"
              meta.name runtime_lane_label
              (String.concat "," reasons)
              raw_input_tok raw_output_tok
              (context_max_of_telemetry response.telemetry));
        (* Cache-token tracking uses OAS-reported counters only. *)
        (match response.usage with
         | Some u when usage_trusted ->
           let cc = u.cache_creation_input_tokens in
           let cr = u.cache_read_input_tokens in
           if cc > 0 then
             Prometheus.inc_counter
               Prometheus.metric_provider_prefix_cache_creation_tokens
               ~delta:(Float.of_int cc) ();
           if cr > 0 then
             Prometheus.inc_counter
               Prometheus.metric_provider_prefix_cache_read_tokens
               ~delta:(Float.of_int cr) ()
         | Some _ | None -> ());
        (* Inference latency histogram for /metrics endpoint.
           Missing telemetry stays a separate counter; zero/negative latency
           increments the zero-latency counter and observes a 1ms floor so the
           histogram still proves the hook ran. *)
        record_llm_inference_latency_metric ~model
          ~telemetry:response.telemetry;
        record_response_content_quality_metric ~keeper_name:meta.name response;
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
          | Some t -> Option.value ~default:0 t.request_latency_ms
          | None -> 0
        in
        let wall_tok_s_opt =
          if usage_trusted then
            wall_tokens_per_second ~usage_missing ~output_tokens:output_tok
              ~telemetry:response.telemetry
          else None
        in
        record_llm_tok_s_metrics ~model ~telemetry:response.telemetry;
        let wall_tok_s = fmt_tok_s wall_tok_s_opt in
        let prompt_tok_s = fmt_tok_s prompt_tok_s_opt in
        let decode_tok_s = fmt_tok_s decode_tok_s_opt in
        let thinking = summarize_thinking_blocks response.content in
        Log.Keeper.info
          "keeper:%s turn=%d total_turns=%d runtime_lane=%s tokens=%d wall_tok_s=%s prompt_tok_s=%s decode_tok_s=%s latency_ms=%d thinking_present=%b thinking_blocks=%d thinking_chars=%d redacted_thinking_blocks=%d thinking_kind=%s"
          meta.name turn meta.runtime.usage.total_turns model total_tok
          wall_tok_s prompt_tok_s decode_tok_s latency_ms
          thinking.thinking_present
          thinking.thinking_blocks
          thinking.thinking_chars
          thinking.redacted_thinking_blocks
          thinking.thinking_kind;
        (* Emit per-turn cost event for task attribution.
           cost_usd from OAS Pricing.annotate_response_cost (oas#393 resolved). *)
        (match trajectory_acc with
         | Some acc ->
           emit_cost_event ~masc_root:acc.masc_root
             ~agent_name:meta.name ~task_id:acc.task_id
             ~model ~input_tokens:raw_input_tok ~output_tokens:raw_output_tok
             ~cost_usd:cost_usd_for_event ~usage_missing
             ~usage_trust
             ?telemetry:response.telemetry ()
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
                 (key_type, `String sse_turn_complete);
                 (key_name, `String meta.name);
                 (key_generation, `Int generation);
                 (key_turn, `Int turn);
                 (key_model_used, `Null);
                 (key_input_tokens, `Int input_tok);
                 (key_output_tokens, `Int output_tok);
                 (key_has_state_block, `Bool has_state_block);
                 (key_cost_usd, `Float turn_cost_usd);
                 (key_tool_calls_made, `Int !tool_call_count_ref);
                 (key_total_turns, `Int meta.runtime.usage.total_turns);
                 (key_ts_unix, `Float (Unix.gettimeofday ()));
               ])
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             (* P2 silent-failure fix: turn-complete event was previously
                dropped without trace.  Dashboard's per-turn marker would
                go missing intermittently and operators had no signal that
                the broadcast itself failed.  PR-C (#11075) added a
                broadcast-failures counter on the SSE side, but it only
                catches per-client failures inside broadcast_impl —
                exceptions thrown from Sse.broadcast at the call boundary
                bypass that counter.  Logging here makes the loss visible
                at the producer site. *)
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_lifecycle_callback_failures
               ~labels:[(label_keeper, meta.name); (label_callback, callback_label_after_turn_sse_broadcast)]
               ();
             Log.Keeper.warn
               "keeper:%s turn=%d sse_turn_complete broadcast failed: %s"
               meta.name turn (Printexc.to_string exn));
        (* Reset same-name streak at turn boundary so it doesn't
           carry across turns (e.g., 4 calls in turn N + 1 in turn N+1
           should not hit threshold 5). *)
        streak_state.Keeper_guards.entry <- ("", 0);
        tool_call_count_ref := 0;
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);

    post_tool_use = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.PostToolUse { tool_name; input; output; duration_ms = hook_duration_ms; _ } ->
        record_progress ("tool_completed:" ^ tool_name);
        incr tool_call_count_ref;
        let output_text = match output with
          | Ok { Agent_sdk.Types.content; _ } -> content
          | Error { Agent_sdk.Types.message; _ } -> message
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
        (* Persistent tool call I/O log for dashboard inspector.
           tool_start_time is keeper-local (one ref per make_hooks call).
           Tool calls within Agent.run are sequential, so no race. *)
        let duration_ms =
          if hook_duration_ms > 0.0
          then hook_duration_ms
          else (Time_compat.now () -. !tool_start_time) *. ms_per_second
        in
        let model =
          current_keeper_model !meta_ref
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
            , approval_mode ) =
          Keeper_tool_call_log.get_turn_context
            ~keeper_name:(!meta_ref).name ()
        in
        (try
           Keeper_tool_call_log.log_call
             ~keeper_name:(!meta_ref).name
             ~tool_name ~input ~output_text
             ~success:(outcome = "ok") ~duration_ms
             ~model:(current_keeper_model !meta_ref)
             ?lane ?tool_choice ?thinking_enabled ?thinking_budget
             ?prompt_fingerprint
             ?trace_id ?session_id ?turn ?keeper_turn_id ?task_id ?goal_ids
             ?sandbox_profile ?network_mode ?approval_mode
             ~result_bytes ?truncated_to ()
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             (* P2 silent-failure fix (same pattern as the broadcast site
                above at line ~1098): tool-call audit log write failures
                were dropped without trace.  Loss of these rows leaves
                downstream replay / debugging tools with gaps that look
                identical to "no tool calls in this turn." *)
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_lifecycle_callback_failures
               ~labels:[(label_keeper, (!meta_ref).name); (label_callback, callback_label_post_tool_log_write)]
               ();
             Log.Keeper.warn
               "keeper:%s tool=%s log_call write failed: %s"
               (!meta_ref).name tool_name (Printexc.to_string exn));
        (try
           append_pr_review_action_metric
             ~config
             ~meta:(!meta_ref)
             ~generation
             ~tool_name
             ~input
             ~output_text
             ~transport_success:(outcome = "ok")
             ~duration_ms
             ()
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_lifecycle_callback_failures
               ~labels:
                 [
                   (label_keeper, (!meta_ref).name);
                   (label_callback, callback_label_pr_review_action_metrics_append);
                 ]
               ();
             Log.Keeper.warn
               "keeper:%s tool=%s pr_review_action metric append failed: %s"
               (!meta_ref).name tool_name (Printexc.to_string exn));
        (try
           append_pr_work_action_metrics
             ~config
             ~meta:(!meta_ref)
             ~generation
             ~tool_name
             ~input
             ~output_text
             ~transport_success:(outcome = "ok")
             ~duration_ms
             ()
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_lifecycle_callback_failures
               ~labels:
                 [
                   (label_keeper, (!meta_ref).name);
                   (label_callback, callback_label_pr_work_action_metrics_append);
                 ]
               ();
             Log.Keeper.warn
               "keeper:%s tool=%s pr_work_action metric append failed: %s"
               (!meta_ref).name tool_name (Printexc.to_string exn));
        (match trajectory_acc with
         | None -> ()
         | Some acc ->
           let keeper_name = (!meta_ref).name in
           let trace_id = acc.Trajectory.trace_id in
           let safe_input =
             Observability_redact.redact_json_value input
           in
           let safe_output =
             Observability_redact.redact_preview
               ~max_len:4000
               output_text
           in
           let runtime_contract =
             Keeper_tool_call_log.runtime_contract_json_for_call
               ~keeper_name
               ~model
               ()
           in
           let action_radius =
             Keeper_tool_call_log.action_radius_json_for_call
               ~keeper_name
               ~tool_name
               ~input:safe_input
               ~success:(outcome = "ok")
               ~duration_ms
               ?error:(if outcome = "ok" then None else Some safe_output)
               ()
           in
           let now = Time_compat.now () in
           let entry : Trajectory.tool_call_entry =
             {
               ts = now;
               ts_iso = Masc_domain.iso8601_of_unix_seconds now;
               turn = acc.Trajectory.turn;
               round = Trajectory.calls_in_current_turn acc + 1;
               tool_name;
               args_json = Yojson.Safe.to_string safe_input;
               gate_decision = Trajectory.Pass;
               result = Some safe_output;
               duration_ms = trajectory_duration_ms duration_ms;
               error = (if outcome = "ok" then None else Some safe_output);
               cost_usd = Trajectory.tool_cost_estimate tool_name;
             }
           in
           Trajectory.record_entry
             ~runtime_contract
             ~action_radius
             ~on_persist_error:(fun exn ->
               Telemetry_coverage_gap.record
                 ~masc_root:acc.Trajectory.masc_root
                 ~source:"trajectory_tool_call"
                 ~producer:"keeper_hooks_oas.post_tool_use"
                 ~durable_store:
                   (Trajectory.trajectory_path acc.Trajectory.masc_root
                      acc.Trajectory.keeper_name trace_id)
                 ~dashboard_surface:"/api/v1/keepers/:name/tool-stats"
                 ~stale_reason:"trajectory_append_failed"
                 ~keeper_name
                 ~trace_id
                 ~error:(Printexc.to_string exn)
                 ())
             acc
             entry);
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
              Prometheus.inc_counter
                Keeper_metrics.metric_keeper_lifecycle_callback_failures
                ~labels:[(label_keeper, (!meta_ref).name); (label_callback, callback_label_on_tool_executed)]
                ();
              Log.Keeper.error "keeper:%s on_tool_executed callback failed for %s: %s"
                (!meta_ref).name tool_name (Printexc.to_string exn));
        if is_keeper_board_write_tool_name tool_name then
          Log.Keeper.debug "keeper:%s social_event tool=%s"
            (!meta_ref).name tool_name;
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);

    (* pre_tool_use is provided by [guard_chain] below via Hooks.compose.
       The guard chain (timing + custom + streak + deny + cost +
       destructive + governance_approval) is composed with these
       non-gate hooks at the end of [make_hooks]. *)

    on_stop = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.OnStop { reason; _ } ->
        Prometheus.inc_counter Keeper_metrics.metric_keeper_oas_on_stop
          ~labels:
            [
              (label_keeper, (!meta_ref).name);
              (label_stop_reason, stop_reason_to_label reason);
            ]
          ();
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);

    on_idle = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.OnIdle { consecutive_idle_turns; tool_names; _ } ->
        keeper_idle_decision ~meta_ref ~consecutive_idle_turns ~tool_names
      | _ -> Agent_sdk.Hooks.Continue);

    on_idle_escalated = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.OnIdleEscalated
          { severity; consecutive_idle_turns; tool_names; _ } ->
        let decision =
          keeper_idle_decision ~meta_ref ~consecutive_idle_turns ~tool_names in
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_oas_on_idle_escalated
          ~labels:
            [
              (label_keeper, (!meta_ref).name);
              (label_severity, idle_severity_to_label severity);
              (label_decision, idle_decision_to_label decision);
            ]
          ();
        decision
      | _ -> Agent_sdk.Hooks.Continue);

    on_error = Some (function
      | Agent_sdk.Hooks.OnError { detail; context = err_ctx } ->
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_lifecycle_callback_failures
          ~labels:[(label_keeper, (!meta_ref).name); (label_callback, callback_label_on_error)]
          ();
        Log.Keeper.error "keeper:%s on_error: %s (context: %s)"
          (!meta_ref).name detail err_ctx;
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);

    on_tool_error = Some (function
      | Agent_sdk.Hooks.OnToolError { tool_name; error } ->
        if tool_error_is_workflow_rejection error
        then
          Log.Keeper.warn "keeper:%s tool_workflow_rejection: %s — %s"
            (!meta_ref).name tool_name error
        else (
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_lifecycle_callback_failures
            ~labels:[(label_keeper, (!meta_ref).name); (label_callback, callback_label_on_tool_error)]
            ();
          Log.Keeper.error "keeper:%s tool_error: %s — %s"
            (!meta_ref).name tool_name error);
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);

    post_tool_use_failure = Some (function
      | Agent_sdk.Hooks.PostToolUseFailure { tool_name; error; _ } ->
        let meta = !meta_ref in
        (* The richer counterpart
             "tool <name> returned error result (n/max): <detail>"
           is already emitted at ERROR by keeper_tools_oas before this
           hook runs. Emitting a second ERROR here with the same error
           content produces paired duplicate lines per tool failure —
           keep a debug trace for hook-chain readers only. *)
        Log.Keeper.debug "keeper:%s tool_use_failure: %s — %s"
          meta.name tool_name error;
        (* #9919: this path is a count event, not a heuristic decision. *)
        record_tool_use_failure ~keeper_name:meta.name ~tool_name;
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);
  }
  in
  (* Guards fire first (outer). If all return Continue, non_gate_hooks
     fire for the remaining slots (inner). pre_tool_use lives in
     guard_chain only; non_gate_hooks has it None, so Hooks.compose
     keeps guard_chain's pre_tool_use verbatim. *)
  Agent_sdk.Hooks.compose ~outer:guard_chain ~inner:non_gate_hooks

module For_testing = struct
  let pr_review_action_metric_event_of_tool_io =
    pr_review_action_metric_event_of_tool_io

  let pr_work_action_metric_events_of_tool_io =
    pr_work_action_metric_events_of_tool_io
end

(** Static introspection of hook slot configuration.
    Returns a JSON summary of which hook slots are active, their gates/effects,
    and the deny list. Used by the dashboard to display hook status. *)
let hook_slot_json ?(features = []) ?(gates = []) ?(effects = [])
    ?reason ~(active : bool) ~(source : string) () : Yojson.Safe.t =
  let list_field name values =
    match values with
    | [] -> []
    | xs -> [ (name, `List (List.map (fun s -> `String s) xs)) ]
  in
  `Assoc
    ([
       (key_active, `Bool active);
       (key_source, `String source);
     ]
     @ (match reason with
       | None -> []
       | Some value -> [ (key_reason, `String value) ])
     @ list_field "features" features
     @ list_field "gates" gates
     @ list_field "effects" effects)

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
  (* Build (name, active, json) triples in one place so the active
     flag is captured at construction time rather than recovered by
     re-inspecting the just-built JSON later. *)
  let slot ?features ?gates ?effects ?reason ~active ~source name =
    let features = Option.value features ~default:[] in
    let gates = Option.value gates ~default:[] in
    let effects = Option.value effects ~default:[] in
    let json =
      hook_slot_json ~features ~gates ~effects ?reason ~active ~source ()
    in
    (name, active, json)
  in
  let slot_entries =
    [
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~features:
          [
            "work_discovery_nudge";
            "passive_loop_nudge";
            "utf8_guard";
          ]
        "before_turn";
      slot
        ~active:true
        ~source:"keeper_run_tools"
        ~features:
          [
            "dynamic_context";
            "adaptive_thinking_budget";
            "tool_surface_selection";
            "memory_injection";
          ]
        "before_turn_params";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~effects:
          [
            "sse_broadcast";
            "cost_event";
            "metrics";
            "usage_trust";
            "tool_streak_reset";
          ]
        "after_turn";
      slot
        ~active:true
        ~source:"keeper_guards"
        ~gates:
          [
            "timing";
            "custom_guard";
            "streak_gate";
            "keeper_deny_list";
            (if Option.is_some max_cost_usd
             then "cost_budget"
             else "cost_budget_off");
            (if destructive_check
             then "destructive_pattern"
             else "destructive_pattern_off");
            "governance_approval";
          ]
        "pre_tool_use";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~features:
          [
            "tool_callback";
            "tool_call_log";
            "trajectory";
            "board_write_detection";
            "tool_emission_capture";
          ]
        "post_tool_use";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~effects:[ "tool_use_failure_metric" ]
        "post_tool_use_failure";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~effects:[ "stop_reason_metric" ]
        "on_stop";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~features:[ "repeated_tool_nudge"; "stay_silent_skip" ]
        "on_idle";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~effects:[ "idle_escalation_metric" ]
        "on_idle_escalated";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~effects:[ "wirein_failure_metric"; "keeper_error_log" ]
        "on_error";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~effects:[ "wirein_failure_metric"; "keeper_error_log" ]
        "on_tool_error";
      slot
        ~active:false
        ~source:"not_registered"
        ~reason:"compaction is handled by keeper_post_turn"
        "pre_compact";
      slot
        ~active:false
        ~source:"not_registered"
        ~reason:"compaction is handled by keeper_post_turn"
        "post_compact";
      slot
        ~active:false
        ~source:"not_registered"
        ~reason:"compaction is handled by keeper_post_turn"
        "on_context_compacted";
    ]
  in
  (* Reviewer #13225: counts used to be derived by re-parsing the
     just-built JSON [Assoc] for an "active" field.  If
     [hook_slot_json]'s shape ever drifts (extra wrapper, renamed
     field) the counts would silently desync from reality.  Track
     [active] alongside each slot at build time so the counts are
     decided where the slot is constructed, not by inspecting JSON. *)
  let active_count =
    List.fold_left
      (fun acc (_name, active, _json) -> if active then acc + 1 else acc)
      0 slot_entries
  in
  let total_count = List.length slot_entries in
  let inactive_count = total_count - active_count in
  let slot_names =
    `List (List.map (fun (name, _, _) -> `String name) slot_entries)
  in
  let slot_assoc =
    List.map (fun (name, _active, json) -> (name, json)) slot_entries
  in
  `Assoc [
    (key_scope, `String "keeper_runtime_composite");
    (key_slots, `Assoc slot_assoc);
    ("slot_names", slot_names);
    (key_slot_count, `Int total_count);
    (key_active_slot_count, `Int active_count);
    (key_inactive_slot_count, `Int inactive_count);
    ("deny_list", denied_json);
    (key_deny_list_count, `Int (List.length keeper_denied_tools));
    ("destructive_check_tools", destructive_json);
    ("cost_budget",
      match max_cost_usd with
      | Some v ->
        `Assoc [(key_max_cost_usd, `Float v); (key_active, `Bool true)]
      | None ->
        `Assoc [(key_active, `Bool false)]);
  ]
