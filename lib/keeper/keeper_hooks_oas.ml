(** Keeper_hooks_oas — OAS hooks adapter for Keeper Agent.run().

    Maps keeper-specific behaviors (checkpoint, metrics, social events, and
    passive tool timing) to OAS hook events. Cost is telemetry-only and must
    not reject tool calls. External-effect authorization is owned by the
    normalized execution boundary, not this generic hook adapter.

    @since Phase 4 — Keeper → Agent.run() migration *)


(** Shared type/helper module (intra-library file split, 2026-05-16).
    Hoisted to the top so the rest of this module can refer to its
    shared bindings. *)
include Keeper_hooks_oas_types

(* label_* string constants moved to Keeper_hooks_oas_types
   (intra-library file split, 2026-05-16). *)
(* callback_label_* constants moved to Keeper_hooks_oas_types
   (intra-library file split, 2026-05-16). *)
(* outcome_ok / outcome_error already moved to Keeper_hooks_oas_types in
   step 5; this duplicate block was left behind by accident and is now
   cleaned up. *)


(** Keeper-facing telemetry uses a neutral runtime lane.  Concrete
    provider/model identity belongs to OAS and lower-level runtime adapters.
    RFC-0132 PR-2: telemetry lane label = external boundary; redact via SSOT. *)
let runtime_lane_label = Boundary_redaction.to_string Boundary_redaction.runtime_lane_label

let runtime_lane_of_model (_model : string) : string = runtime_lane_label

let trajectory_duration_ms duration_ms =
  if (not (Float.is_finite duration_ms)) || Float.compare duration_ms 0.0 <= 0
  then 0
  else max 1 (int_of_float (Float.round duration_ms))

(* Inference telemetry redaction moved to Keeper_hooks_oas_types
   (intra-library file split, 2026-05-16). *)

(* usage_has_tokens / current_keeper_model
   / stop_reason_label_* / stop_reason_to_label moved to
   Keeper_hooks_oas_types (intra-library file split, 2026-05-16;
   stop_reason_to_label unified with keeper_hooks_oas_response_metrics
   on 2026-06-24 to remove the duplicate 9-arm match). [include
   Keeper_hooks_oas_types] above re-exports it for the call sites here. *)

let json_value_shape_for_log = function
  | `Assoc fields -> Printf.sprintf "object:%d" (List.length fields)
  | `List values -> Printf.sprintf "array:%d" (List.length values)
  | `String "" -> "string:empty"
  | `String value -> Printf.sprintf "string:%d" (String.length value)
  | `Bool _ -> "bool"
  | `Int _ | `Intlit _ -> "int"
  | `Float _ -> "number"
  | `Null -> "null"

let tool_input_shape_for_log = function
  | `Assoc [] -> "object:0"
  | `Assoc fields ->
    fields
    |> List.sort (fun (left, _) (right, _) -> String.compare left right)
    |> List.map (fun (key, value) -> key ^ "=" ^ json_value_shape_for_log value)
    |> String.concat ","
  | other -> json_value_shape_for_log other

let tool_input_keys_for_log = function
  | `Assoc [] -> "-"
  | `Assoc pairs -> String.concat "," (List.map fst pairs)
  | _ -> "-"

let one_line_preview_for_log text =
  text
  |> String.map (function
    | '\n' | '\r' | '\t' -> ' '
    | c -> c)
  |> String_util.utf8_safe ~max_bytes:240 ~suffix:"..."
  |> String_util.to_string

let failure_class_of_tool_error_json json =
  let direct = Safe_ops.json_string_opt "failure_class" json in
  let nested =
    match Json_util.assoc_member_opt "detail" json with
    | Some (`Assoc _ as detail) -> Safe_ops.json_string_opt "failure_class" detail
    | _ -> None
  in
  match direct with
  | Some _ -> direct
  | None -> nested

let failure_class_of_tool_error_text error =
  try
    let json = Yojson.Safe.from_string error in
    failure_class_of_tool_error_json json
  with
  | Yojson.Json_error _ | Failure _ -> None

let tool_error_failure_class ?base_path error =
  match Tool_output.decode_from_oas error with
  | Tool_output.Inline inline -> failure_class_of_tool_error_text inline
  | Tool_output.Stored { sha256; preview; _ } ->
    let from_store =
      match base_path with
      | None -> None
      | Some base_path ->
        Safe_ops.protect ~default:None (fun () ->
            let store = Tool_blob_store.create ~base_path in
            match Tool_blob_store.fetch store ~sha256 with
            | Some payload -> failure_class_of_tool_error_text payload
            | None -> None)
    in
    (match from_store with
     | Some _ -> from_store
     | None -> failure_class_of_tool_error_text preview)

let self_correcting_tool_failure_class ?base_path error =
  match tool_error_failure_class ?base_path error with
  | Some failure_class -> (
    match Tool_result.tool_failure_class_of_string failure_class with
    | Some Tool_result.Workflow_rejection ->
      Some (Tool_result.tool_failure_class_to_string Tool_result.Workflow_rejection)
    | Some Tool_result.Policy_rejection ->
      Some (Tool_result.tool_failure_class_to_string Tool_result.Policy_rejection)
    | Some (Tool_result.Transient_error | Tool_result.Runtime_failure) | None -> None)
  | None -> None

include Keeper_hooks_oas_response_metrics

(* cost_status / thinking_log_summary types + telemetry helpers
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
    "usage was missing" apart from "pricing catalog miss" or a
    structurally free runtime. Each silent path collapsed
    to the same [0.0] field and the operator could only see
    "tracking is broken" without the next concrete action.

    Bounded source values:
    - [computed]              — a non-zero cost was reported by OAS.
    - [missing_usage]         — no usage payload from the provider.
    - [unmetered_provider]    — OAS/runtime explicitly marks the call free.
    - [oas_cost_unreported]   — OAS returned usage but no cost. *)
include Keeper_hooks_oas_cost_events

(** Build OAS hooks for a keeper agent.

    All keepers receive the full tool set unconditionally.
    Cost events are emitted per turn to [.masc/costs.jsonl]. Cost is an
    observation and is not part of the pre-tool decision surface.

    @param meta_ref Mutable ref to keeper metadata
    @param generation Current generation counter
    @param on_tool_executed Optional callback after each tool execution
    @param trajectory_acc Optional trajectory accumulator for cost attribution

    Issue #8597 #3-5: dropped [~config], [~session], [~ctx_snapshot]. The
    closure body never read them; the docstring even admitted [ctx_snapshot]
    was "reserved, unused". State now flows through [meta_ref] (mutable) and
    the explicit [on_tool_executed] callback. *)

let make_hooks
    ~(config : Workspace.config)
    ~(meta_ref : Keeper_meta_contract.keeper_meta ref)
    ~(turn_ctx_cell : Keeper_tool_call_log.turn_ctx_cell)
    ~(generation : int)
    ?(on_tool_executed :
        tool_name:string -> input:Yojson.Safe.t -> output_text:string ->
        success:bool -> duration_ms:float -> provider:string ->
        typed_outcome:Keeper_tool_outcome.t option -> unit =
        fun ~tool_name:_ ~input:_ ~output_text:_ ~success:_ ~duration_ms:_ ~provider:_ ~typed_outcome:_ -> ())
    ?(trajectory_acc : Trajectory.accumulator option)
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
  ignore trajectory_acc;
  let hooks =
    { Agent_sdk.Hooks.empty with
    pre_tool_use = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.PreToolUse _ ->
        tool_start_time := Time_compat.now ();
        Agent_sdk.Hooks.Continue
      | _event -> Agent_sdk.Hooks.Continue);

    before_turn = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.BeforeTurn _ ->
        record_progress "sdk_before_turn";
        Agent_sdk.Hooks.Continue
      | _event -> Agent_sdk.Hooks.Continue);

    after_turn = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.AfterTurn { turn; response } ->
        record_progress "sdk_after_turn";
        let meta = !meta_ref in
        let model = resolve_after_turn_model ~keeper_name:meta.name ~response in
        let usage_trust =
          classify_usage_trust ?usage:response.usage ()
        in
        record_usage_anomaly_metrics ~keeper_name:meta.name usage_trust;
        let raw_input_tok, raw_output_tok =
          match response.usage with
          | Some u -> u.input_tokens, u.output_tokens
          | None -> 0, 0
        in
        let raw_cache_creation_input_tokens, raw_cache_read_input_tokens =
          match response.usage with
          | Some u -> u.cache_creation_input_tokens, u.cache_read_input_tokens
          | None -> 0, 0
        in
        let input_tok, output_tok, turn_cost_usd, usage_missing =
          match response.usage with
          | Some u ->
              ( u.input_tokens,
                u.output_tokens,
                oas_reported_cost u,
                false )
          | None -> (0, 0, 0.0, true)
        in
        let cost_usd_for_event = turn_cost_usd in
        let total_tok = input_tok + output_tok in
        (match usage_trust with
         | Keeper_usage_trust.Usage_untrusted reasons when not usage_missing ->
          if Keeper_usage_trust.warns_operator usage_trust then
            Log.Keeper.warn ~keeper_name:meta.name
              "after_turn usage telemetry untrusted runtime_lane=%s reasons=%s input=%d output=%d context_max=%d"
              runtime_lane_label
              (String.concat "," reasons)
              raw_input_tok raw_output_tok
              (context_max_of_telemetry response.telemetry)
          else
            Log.Keeper.info ~keeper_name:meta.name
              "after_turn usage telemetry unavailable runtime_lane=%s reasons=%s input=%d output=%d context_max=%d"
              runtime_lane_label
              (String.concat "," reasons)
              raw_input_tok raw_output_tok
              (context_max_of_telemetry response.telemetry)
         | Keeper_usage_trust.Usage_missing
         | Keeper_usage_trust.Usage_trusted
         | Keeper_usage_trust.Usage_untrusted _ -> ());
        (* Provider label for per-provider/model counters.
           Resolved once from telemetry; falls back to the
           redacted runtime_lane_label when unavailable. *)
        let provider_label =
          match response.telemetry with
          | Some { provider_kind = Some pk; _ } ->
            Llm_provider.Provider_config.string_of_provider_kind pk
          | _ -> runtime_lane_label
        in
        let cache_creation_input_tokens, cache_read_input_tokens =
          match response.usage with
          | Some u ->
              u.cache_creation_input_tokens, u.cache_read_input_tokens
          | None -> 0, 0
        in
        let reasoning_output_tokens =
          match response.telemetry with
          | Some { reasoning_tokens = Some rt; _ } when rt > 0 -> rt
          | _ -> 0
        in
        let request_stream =
          match response.telemetry with
          | Some { ttfrc_ms = Some _; _ } -> Some true
          | _ -> None
        in
        (* Cache-token tracking uses OAS-reported counters only. *)
        let cc = cache_creation_input_tokens in
        let cr = cache_read_input_tokens in
        if cc > 0 then
             Otel_metric_store.inc_counter
               Otel_metric_store.metric_provider_prefix_cache_creation_tokens
               ~delta:(Float.of_int cc) ();
        if cr > 0 then begin
          Otel_metric_store.inc_counter
            Otel_metric_store.metric_provider_prefix_cache_read_tokens
            ~delta:(Float.of_int cr) ();
          (* Per-provider/model cache-read counter for Otel_metric_store
             dashboards.  The legacy unlabelled counter above
             remains for backward compatibility. *)
          Otel_metric_store.inc_counter
            Otel_metric_store.metric_llm_provider_cache_read_tokens
            ~labels:[ ("provider", provider_label); ("model", model) ]
            ~delta:(Float.of_int cr)
            ()
        end;
        (* Per-provider/model reasoning-token counter.  Available via
           [inference_telemetry.reasoning_tokens] on select providers
           (Anthropic extended thinking, DeepSeek, etc.). *)
        if reasoning_output_tokens > 0 then
           Otel_metric_store.inc_counter
             Otel_metric_store.metric_llm_provider_reasoning_tokens
             ~labels:[ ("provider", provider_label); ("model", model) ]
             ~delta:(Float.of_int reasoning_output_tokens)
             ();
        Llm_metric_bridge.emit_usage_details
          ~provider:provider_label
          ~model_id:model
          ~cache_creation_input_tokens
          ~cache_read_input_tokens
          ~reasoning_output_tokens
          ?request_stream
          ~finish_reason:(stop_reason_to_label response.stop_reason)
          ();
        (* Inference latency histogram for telemetry export.
           Missing telemetry stays a separate counter; zero/negative latency
           increments the zero-latency counter and observes a 1ms floor so the
           histogram still proves the hook ran. *)
        record_llm_inference_latency_metric ~telemetry:response.telemetry;
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
          | None | Some { timings = None; _ } -> None, None
        in
        let latency_ms =
          match response.telemetry with
          | Some t -> Option.value ~default:0 t.request_latency_ms
          | None -> 0
        in
        let wall_tok_s_opt =
          wall_tokens_per_second ~usage_missing ~output_tokens:output_tok
            ~telemetry:response.telemetry
        in
        record_llm_tok_s_metrics ~telemetry:response.telemetry;
        let wall_tok_s = fmt_tok_s wall_tok_s_opt in
        let prompt_tok_s = fmt_tok_s prompt_tok_s_opt in
        let decode_tok_s = fmt_tok_s decode_tok_s_opt in
        let thinking = summarize_thinking_blocks response.content in
        Log.Keeper.info ~keeper_name:meta.name
          "turn=%d total_turns=%d runtime_lane=%s tokens=%d wall_tok_s=%s prompt_tok_s=%s decode_tok_s=%s latency_ms=%d thinking_present=%b thinking_blocks=%d thinking_chars=%d redacted_thinking_blocks=%d thinking_kind=%s"
          turn meta.runtime.usage.total_turns model total_tok
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
             ~input_tokens:raw_input_tok ~output_tokens:raw_output_tok
             ~cost_usd:cost_usd_for_event ~usage_missing
             ~cache_creation_input_tokens:raw_cache_creation_input_tokens
             ~cache_read_input_tokens:raw_cache_read_input_tokens
             ~usage_trust
             ?telemetry:response.telemetry
             ~model:response.model ();
           (* 남김없이: persist THIS turn's reasoning (full, untruncated) every
              turn. The prior single post-run capture (Keeper_agent_run) saved
              only the final turn's thinking; turns 1..N-1 were merely counted
              by the log line above. *)
           Keeper_agent_run_thinking_trajectory.persist_response_content
             ~keeper_name:meta.name ~trajectory_acc:(Some acc) ~turn
             response.content
         | None -> ());
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
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string LifecycleCallbackFailures)
               ~labels:[(label_keeper, meta.name); (label_callback, callback_label_after_turn_sse_broadcast)]
               ();
             Log.Keeper.warn ~keeper_name:meta.name
               "turn=%d sse_turn_complete broadcast failed: %s"
               turn (Printexc.to_string exn));
        tool_call_count_ref := 0;
        Agent_sdk.Hooks.Continue
      | _event -> Agent_sdk.Hooks.Continue);

    post_tool_use = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.PostToolUse
          { tool_name; input; output; duration_ms = hook_duration_ms; tool_use_id; _ } ->
        record_progress ("tool_completed:" ^ tool_name);
        incr tool_call_count_ref;
        (* Extract typed_outcome from structured tool output JSON and strip it
           from the LLM-facing output so the internal metadata does not leak
           into the next turn's context. *)
        let output_text, typed_outcome =
          match output with
          | Ok { Agent_sdk.Types.content; _ } ->
            (match Yojson.Safe.from_string content with
             | json ->
               let typed_outcome =
                 match json with
                 | `Assoc fields ->
                   (match List.assoc_opt "typed_outcome" fields with
                    | Some nested -> Keeper_tool_outcome.of_json nested
                    | None -> None)
                 | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
                   None
               in
               let stripped = Keeper_tool_outcome.strip_from_json json in
               (Yojson.Safe.to_string stripped, typed_outcome)
             | exception _ -> (content, None))
          | Error { Agent_sdk.Types.message; _ } -> (message, None)
        in
        let input_keys = tool_input_keys_for_log input in
        let outcome, out_len = match output with
          | Ok { Agent_sdk.Types.content; _ } -> Tool_result.Ok, String.length content
          | Error { Agent_sdk.Types.message; _ } -> Tool_result.Error, String.length message
        in
        let outcome_s = Tool_result.string_of_tool_call_outcome outcome in
        let input_shape = tool_input_shape_for_log input in
        let error_preview =
          match output with
          | Ok _ -> "-"
          | Error _ ->
            output_text
            |> Observability_redact.redact_preview ~max_len:240
            |> one_line_preview_for_log
        in
        (match outcome with
         | Tool_result.Error -> Log.Keeper.error
         | Tool_result.Ok | Tool_result.Unknown -> Log.Keeper.info)
          "keeper:%s tool_call tool=%s params=[%s] input_shape=[%s] outcome=%s out_len=%d error_preview=%s"
          (!meta_ref).name tool_name input_keys input_shape outcome_s out_len error_preview;
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
            ~success:(outcome = Tool_result.Ok)
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
        (* Full record read: log_call no longer falls back to ambient
           context (RFC-0225 §3.3), so every field this row should carry
           must be passed explicitly from the run's own cell. *)
        let tctx : Keeper_tool_call_log_context.turn_context =
          Keeper_tool_call_log_context.get_turn_context_record
            ~cell:turn_ctx_cell ()
        in
        (* RFC-0233 PR-1: one mint per execution at this dispatch boundary;
           the log_call row and the trajectory entry below share the value
           so downstream views can join the two stores on a single key. *)
        let execution_id = Ids.Execution_id.generate () in
        (* RFC-0233 PR-2: register the provider-call ↔ execution pair now,
           strictly before OAS publishes ToolCompleted for this call, so the
           event bridge can stamp the same id onto the oas:tool_completed
           row (insert happens-before publish happens-before drain). *)
        Keeper_execution_join.record ~tool_use_id
          ~execution_id:(Ids.Execution_id.to_string execution_id);
        (try
           Keeper_tool_call_log.log_call
             ~keeper_name:(!meta_ref).name
             ~tool_name ~input ~output_text
             ~success:(outcome = Tool_result.Ok) ~duration_ms
             ~model:(current_keeper_model !meta_ref)
             ?agent_name:tctx.agent_name
             ?lane:tctx.lane ?tool_choice:tctx.tool_choice
             ?thinking_enabled:tctx.thinking_enabled
             ?thinking_budget:tctx.thinking_budget
             ?prompt_fingerprint:tctx.prompt_fingerprint
             ~execution_id
             ?tool_use_id:(if tool_use_id = "" then None else Some tool_use_id)
             ?trace_id:tctx.trace_id ?session_id:tctx.session_id
             ?generation:tctx.generation
             ?turn:tctx.turn ?keeper_turn_id:tctx.keeper_turn_id
             ?task_id:tctx.task_id ?goal_ids:tctx.goal_ids
             ?sandbox_profile:tctx.sandbox_profile
             ?sandbox_root:tctx.sandbox_root
             ?allowed_paths:tctx.allowed_paths
             ?network_mode:tctx.network_mode
             ?runtime_profile:tctx.runtime_profile
             ~result_bytes ?truncated_to ()
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             (* P2 silent-failure fix (same pattern as the broadcast site
                above at line ~1098): tool-call audit log write failures
                were dropped without trace.  Loss of these rows leaves
                downstream replay / debugging tools with gaps that look
                identical to "no tool calls in this turn." *)
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string LifecycleCallbackFailures)
               ~labels:[(label_keeper, (!meta_ref).name); (label_callback, callback_label_post_tool_log_write)]
               ();
             Log.Keeper.warn ~keeper_name:(!meta_ref).name
               "tool=%s log_call write failed: %s"
               tool_name (Printexc.to_string exn));
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
             Keeper_tool_call_log.runtime_observability_contract_json_for_call
               ~keeper_name
               ~cell:turn_ctx_cell
               ()
           in
           let action_radius =
             Keeper_tool_call_log.action_radius_json_for_call
               ~cell:turn_ctx_cell
               ~tool_name
               ~input:safe_input
               ~success:(outcome = Tool_result.Ok)
               ~duration_ms
               ?error:(if outcome = Tool_result.Ok then None else Some safe_output)
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
               error = (if outcome = Tool_result.Ok then None else Some safe_output);
               cost_usd = Trajectory.tool_cost_estimate tool_name;
               execution_id =
                 Some (Ids.Execution_id.to_string execution_id);
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
                 ~exn
                 ())
             acc
             entry);
        (try
           on_tool_executed
             ~tool_name
             ~input
             ~output_text
             ~success:(outcome = Tool_result.Ok)
             ~duration_ms:summary.duration_ms
             ~provider:summary.provider
             ~typed_outcome
         with Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
              Otel_metric_store.inc_counter
                Keeper_metrics.(to_string LifecycleCallbackFailures)
                ~labels:[(label_keeper, (!meta_ref).name); (label_callback, callback_label_on_tool_executed)]
                ();
              Log.Keeper.error ~keeper_name:(!meta_ref).name "on_tool_executed callback failed for %s: %s"
                tool_name (Printexc.to_string exn));
        Agent_sdk.Hooks.Continue
      | _event -> Agent_sdk.Hooks.Continue);

    on_stop = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.OnStop { reason; _ } ->
        Otel_metric_store.inc_counter Keeper_metrics.(to_string OasOnStop)
          ~labels:
            [
              (label_keeper, (!meta_ref).name);
              (label_stop_reason, stop_reason_to_label reason);
            ]
          ();
        Agent_sdk.Hooks.Continue
      | _event -> Agent_sdk.Hooks.Continue);

    on_error = Some (function
      | Agent_sdk.Hooks.OnError { detail; context = err_ctx } ->
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string LifecycleCallbackFailures)
          ~labels:[(label_keeper, (!meta_ref).name); (label_callback, callback_label_on_error)]
          ();
        Log.Keeper.error ~keeper_name:(!meta_ref).name "on_error: %s (context: %s)"
          detail err_ctx;
        Agent_sdk.Hooks.Continue
      | _event -> Agent_sdk.Hooks.Continue);

    on_tool_error = Some (function
      | Agent_sdk.Hooks.OnToolError { tool_name; error } ->
        let keeper_name = (!meta_ref).name in
        (match self_correcting_tool_failure_class ~base_path:config.base_path error with
         | Some failure_class ->
           Log.Keeper.warn ~keeper_name "tool_%s: %s — %s"
             failure_class tool_name error
         | None ->
           (* Always increment the durable Otel_metric_store signal for real
              tool/runtime failures: noise dedupe is a log-surface concern
              only; the counter carries the count for dashboards and alert
              rules. Deterministic workflow/policy rejections are handled
              above as self-correcting control flow. *)
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string LifecycleCallbackFailures)
             ~labels:
               [ (label_keeper, keeper_name)
               ; (label_callback, callback_label_on_tool_error)
               ]
             ();
           (* λ-HOOK-ERROR (2026-05-19) — typed dedupe of repeated
              [on_tool_error] hook ERROR lines. system_log 1000-line
              sample (keeper:verifier x Execute x 2, lifecycle-worker-fast-1
              × Execute × 2, analyst × masc_transition × 2)
              shows the same (keeper, tool, error) triple recurring across
              time; only the first occurrence carries operator-visible ERROR
              value. See
              lib/keeper_tool_hook_error_state for rationale. *)
           let error_signature = Keeper_tool_hook_error_state.normalize error in
           (match
              Keeper_tool_hook_error_state.record
                ~keeper_name
                ~tool_name
                ~error_signature
                ()
            with
            | `First ->
              Log.Keeper.error ~keeper_name "tool_error: %s — %s"
                tool_name error
            | `Repeated n ->
              Log.Keeper.debug ~keeper_name:keeper_name
                "tool_error repeated (total=%d, dedup): %s — %s"
                n tool_name error
            | `Threshold_silence n ->
              Log.Keeper.error ~keeper_name:keeper_name
                "tool_error threshold-silence after %d identical: %s — %s"
                n tool_name error;
              Otel_metric_store.inc_counter
                Keeper_metrics.(to_string LifecycleCallbackFailures)
                ~labels:
                  [ (label_keeper, keeper_name)
                  ; (label_callback, "on_tool_error_threshold_silence")
                  ]
                ()));
        Agent_sdk.Hooks.Continue
      | _event -> Agent_sdk.Hooks.Continue);

    post_tool_use_failure = Some (function
      | Agent_sdk.Hooks.PostToolUseFailure { tool_name; error; _ } ->
        let meta = !meta_ref in
        (* The richer counterpart
             "tool <name> returned error result (n/max): <detail>"
           is already emitted at ERROR by keeper_tools_oas before this
           hook runs. Emitting a second ERROR here with the same error
           content produces paired duplicate lines per tool failure —
           keep a debug trace for hook-chain readers only. *)
        Log.Keeper.debug ~keeper_name:meta.name "tool_use_failure: %s — %s"
          tool_name error;
        (* #9919: this path is a count event, not a heuristic decision. *)
        record_tool_use_failure ~keeper_name:meta.name ~tool_name;
        Agent_sdk.Hooks.Continue
      | _event -> Agent_sdk.Hooks.Continue);
  }
  in
  hooks

let hook_introspection_json () : Yojson.Safe.t =
  Keeper_hooks_oas_introspection.hook_introspection_json ()

module For_testing = struct
  let tool_input_shape_for_log = tool_input_shape_for_log
  let tool_input_keys_for_log = tool_input_keys_for_log
end
