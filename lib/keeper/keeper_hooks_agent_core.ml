(** Keeper_hooks_agent_core — AGENT_CORE hooks adapter for Keeper Agent.run().

    Maps keeper-specific behaviors (checkpoint, metrics, social events, and
    passive tool timing) to AGENT_CORE hook events. Cost is telemetry-only and must
    not reject tool calls. External-effect authorization is owned by the
    normalized execution boundary, not this generic hook adapter.

    @since Phase 4 — Keeper → Agent.run() migration *)


(** Shared type/helper module (intra-library file split, 2026-05-16).
    Hoisted to the top so the rest of this module can refer to its
    shared bindings. *)
include Keeper_hooks_agent_core_types

(* label_* string constants moved to Keeper_hooks_agent_core_types
   (intra-library file split, 2026-05-16). *)
(* callback_label_* constants moved to Keeper_hooks_agent_core_types
   (intra-library file split, 2026-05-16). *)
(* outcome_ok / outcome_error already moved to Keeper_hooks_agent_core_types in
   step 5; this duplicate block was left behind by accident and is now
   cleaned up. *)


(** Keeper-facing telemetry uses a neutral runtime lane.  Concrete
    provider/model identity belongs to AGENT_CORE and lower-level runtime adapters.
    RFC-0132 PR-2: telemetry lane label = external boundary; redact via SSOT. *)
let runtime_lane_label = Boundary_redaction.to_string Boundary_redaction.runtime_lane_label
let sse_turn_complete = "keeper_turn_complete"
let sse_turn_observation = "keeper_turn_observation"

let broadcast_resolved_turn_complete
      ~keeper_name
      ~turn
      ~tool_calls_made
      ~total_turns
      ~(usage_resolution : Keeper_usage_resolution.t)
  =
  let usage_field field =
    match usage_resolution.delta with
    | Some usage -> `Int (field usage)
    | None -> `Null
  in
  let cost_usd =
    match usage_resolution.delta with
    | Some { cost_usd = Some cost; _ } -> `Float cost
    | Some { cost_usd = None; _ } | None -> `Null
  in
  Sse.broadcast
    (`Assoc
      [ key_type, `String sse_turn_complete
      ; key_name, `String keeper_name
      ; key_turn, `Int turn
      ; key_model_used, `Null
      ; ( key_input_tokens
        , usage_field (fun usage -> usage.Keeper_usage_resolution.input_tokens) )
      ; ( key_output_tokens
        , usage_field (fun usage -> usage.Keeper_usage_resolution.output_tokens) )
      ; key_cost_usd, cost_usd
      ; key_tool_calls_made, `Int tool_calls_made
      ; ( key_cache_read_tokens
        , usage_field (fun usage -> usage.Keeper_usage_resolution.cache_read_input_tokens) )
      ; key_cache_n, `Null
      ; key_prompt_n, `Null
      ; key_total_turns, `Int total_turns
      ; "usage_resolution", Keeper_usage_resolution.to_json usage_resolution
      ; key_ts_unix, `Float (Time_compat.now ())
      ])
;;

let trajectory_duration_ms duration_ms =
  if (not (Float.is_finite duration_ms)) || Float.compare duration_ms 0.0 <= 0
  then 0
  else max 1 (int_of_float (Float.round duration_ms))

(* Inference telemetry redaction moved to Keeper_hooks_agent_core_types
   (intra-library file split, 2026-05-16). *)

(* usage_has_tokens / current_keeper_model
   / stop_reason_label_* / stop_reason_to_label moved to
   Keeper_hooks_agent_core_types (intra-library file split, 2026-05-16;
   stop_reason_to_label unified with keeper_hooks_agent_core_response_metrics
   on 2026-06-24 to remove the duplicate 9-arm match). [include
   Keeper_hooks_agent_core_types] above re-exports it for the call sites here. *)

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

include Keeper_hooks_agent_core_response_metrics

(* cost_status / thinking_log_summary types + telemetry helpers
   moved to Keeper_hooks_agent_core_types (intra-library file split, 2026-05-16).
   The include is hoisted to the top of this module — see the comment
   near the keeper deny-list definition. *)

(* cost_source_unmetered_provider / cost_source_computed / agent_core_reported_cost
   moved to Keeper_hooks_agent_core_types (intra-library file split, 2026-05-16). *)

(* type tool_execution_summary + builder moved to Keeper_hooks_agent_core_types
   (intra-library file split, 2026-05-16). *)

(** #10318: classify why [cost_usd] ended up as it did so the
    ledger entry is self-describing.  Pre-fix [costs.jsonl] showed
    100% [cost_usd=0] across 1697 entries with no way to tell
    "usage was missing" apart from "pricing catalog miss" or a
    structurally free runtime. Each silent path collapsed
    to the same [0.0] field and the operator could only see
    "tracking is broken" without the next concrete action.

    Bounded source values:
    - [computed]              — a non-zero cost was reported by AGENT_CORE.
    - [missing_usage]         — no usage payload from the provider.
    - [unmetered_provider]    — AGENT_CORE/runtime explicitly marks the call free.
    - [agent_core_cost_unreported]   — AGENT_CORE returned usage but no cost. *)
include Keeper_hooks_agent_core_cost_events

(** Build AGENT_CORE hooks for a keeper agent.

    All keepers receive the full tool set unconditionally.
    Cost events are emitted per turn to the date-split [.masc/costs/] store. Cost is an
    observation and is not part of the pre-tool decision surface.

    @param meta_ref Mutable ref to keeper metadata
    @param on_tool_executed Optional callback after each tool execution
    @param trajectory_acc Optional trajectory accumulator for cost attribution

    Issue #8597 #3-5: dropped [~config], [~session], [~ctx_snapshot]. The
    closure body never read them; the docstring even admitted [ctx_snapshot]
    was "reserved, unused". State now flows through [meta_ref] (mutable) and
    the explicit [on_tool_executed] callback. *)

let cost_usd_json = function
  | Some cost -> `Float cost
  | None -> `Null

let usage_missing_of_usage = function
  | None -> true
  | Some usage -> not (usage_has_tokens usage)

type tool_stream_observation =
  | Runtime_attempt_started of
      { runtime_id : string
      ; lane_attempt_index : int
      ; checkpoint_owner : Runtime_execution.checkpoint_owner
      }
  | Turn_collected of
      { turn : int
      ; tool_source_map : Agent_core.Hooks.admitted_tool_source_map
      }
  | Turn_closed_without_sources of { turn : int }

let make_hooks
    ~(config : Workspace.config)
    ~(meta_ref : Keeper_meta_contract.keeper_meta ref)
    ~(turn_ctx_cell : Keeper_tool_call_log.turn_ctx_cell)
    ~(trace_id : string)
    ~(keeper_turn_id : int)
    ~(on_after_turn_ordinal : int -> unit)
    ?(on_tool_stream_observation : tool_stream_observation -> unit = fun _ -> ())
    ?(on_after_turn_response :
        response:Agent_core.Types.api_response -> unit =
        fun ~response:_ -> ())
    ?(on_tool_executed :
        tool_name:string -> input:Yojson.Safe.t -> output_text:string ->
        success:bool -> duration_ms:float -> provider:string ->
        typed_outcome:Keeper_tool_outcome.t option -> unit =
        fun ~tool_name:_ ~input:_ ~output_text:_ ~success:_ ~duration_ms:_ ~provider:_ ~typed_outcome:_ -> ())
    ?tool_result_commit_required
    ?on_tool_result_ready
    ?(trajectory_acc : Trajectory.accumulator option)
    ()
  : Agent_core.Hooks.hooks =
  (* Per-turn tool call counter for SSE enrichment.
     Incremented in post_tool_use, reset in after_turn. *)
  let tool_call_count_ref = ref 0 in
  let tool_result_commit_required =
    Option.value
      ~default:(fun () -> Option.is_some on_tool_result_ready)
      tool_result_commit_required
  in
  let record_progress event_kind =
    Keeper_registry.record_turn_progress
      ~base_path:config.base_path
      (!meta_ref).name
      ~event_kind
  in
  let hooks =
    { Agent_core.Hooks.empty with
    before_turn = Some (fun event ->
      match event with
      | Agent_core.Hooks.BeforeTurn _ ->
        record_progress "agent_core_before_turn";
        Agent_core.Hooks.Continue
      | _event -> Agent_core.Hooks.Continue);

    after_turn = Some (fun event ->
      match event with
      | Agent_core.Hooks.AfterTurn { turn; response; tool_source_map } ->
        on_after_turn_ordinal turn;
        (match tool_source_map with
         | Some tool_source_map ->
           on_tool_stream_observation
             (Turn_collected { turn; tool_source_map })
         | None ->
           on_tool_stream_observation (Turn_closed_without_sources { turn }));
        on_after_turn_response ~response;
        record_progress "agent_core_after_turn";
        (* Tail of this agent-core turn's visible text, for the same glance.
           Exhaustive over content_block on purpose: a new text-bearing
           variant must be a compile-time decision here, not a silent drop. *)
        (let visible_text =
           response.content
           |> List.filter_map (fun (block : Agent_core.Types.content_block) ->
                  match block with
                  | Agent_core.Types.Text text -> Some text
                  | Agent_core.Types.Thinking _
                  | Agent_core.Types.ReasoningDetails _
                  | Agent_core.Types.RedactedThinking _
                  | Agent_core.Types.ToolUse _
                  | Agent_core.Types.ToolResult _
                  | Agent_core.Types.Image _
                  | Agent_core.Types.Document _
                  | Agent_core.Types.Audio _ -> None)
           |> String.concat "\n"
         in
         Keeper_turn_preview.note_text
           ~keeper_name:(!meta_ref).name
           ~now:(Unix.gettimeofday ())
           visible_text);
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
        let input_tok, output_tok, turn_cost_usd =
          match response.usage with
          | Some u ->
              ( u.input_tokens,
                u.output_tokens,
                agent_core_reported_cost u )
          | None -> (0, 0, 0.0)
        in
        let usage_missing = usage_missing_of_usage response.usage in
        let cost_usd_for_event = turn_cost_usd in
        let cost_usd_for_sse =
          match response.usage with
          | Some usage -> cost_usd_json usage.cost_usd
          | None -> cost_usd_json None
        in
        let total_tok = input_tok + output_tok in
        let context_max_log =
          match context_max_of_telemetry response.telemetry with
          | Some n -> string_of_int n
          | None -> "-"
        in
        (match usage_trust with
         | Keeper_usage_trust.Usage_untrusted reasons when not usage_missing ->
          if Keeper_usage_trust.warns_operator usage_trust then
            Log.Keeper.warn ~keeper_name:meta.name
              "after_turn usage telemetry untrusted runtime_lane=%s reasons=%s input=%d output=%d context_max=%s"
              runtime_lane_label
              (String.concat "," reasons)
              raw_input_tok raw_output_tok
              context_max_log
          else
            Log.Keeper.info ~keeper_name:meta.name
              "after_turn usage telemetry unavailable runtime_lane=%s reasons=%s input=%d output=%d context_max=%s"
              runtime_lane_label
              (String.concat "," reasons)
              raw_input_tok raw_output_tok
              context_max_log
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
        (* Provider usage may be conversation-cumulative. Cache counters are
           emitted once from the Keeper usage resolution after the runtime
           supplies its typed scope and fresh/resumed identity. *)
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
           Gemini populate [request_latency_ms] (patched in AGENT_CORE api.ml) but
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
        let latency_ms_opt =
          match response.telemetry with
          | Some t -> t.request_latency_ms
          | None -> None
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
        (* [tokens] alone is a numerator. Runtimes in one fleet declare
           windows from 200K to 1M, so the same absolute count means a
           different amount of pressure per keeper and the log cannot be
           compared across them. The window is already on the turn record;
           carrying it here makes the log self-sufficient. An absent window
           renders ["-"], the same as the other unread counters on this line;
           it used to render [0], which reads as a window of zero (25 lines in
           the two hours to 2026-08-22T02:03Z). *)
        let fmt_int_opt = function
          | Some v -> string_of_int v
          | None -> "-"
        in
        let context_window =
          fmt_int_opt (context_max_of_telemetry response.telemetry)
        in
        let latency_ms = fmt_int_opt latency_ms_opt in
        let cache_n_log, prompt_n_log =
          match response.telemetry with
          | Some { timings = Some t; _ } ->
            fmt_int_opt t.cache_n, fmt_int_opt t.prompt_n
          | Some { timings = None; _ } | None -> "-", "-"
        in
        Log.Keeper.info ~keeper_name:meta.name
          "turn=%d total_turns=%d runtime_lane=%s tokens=%d context_window=%s wall_tok_s=%s prompt_tok_s=%s decode_tok_s=%s cache_n=%s prompt_n=%s latency_ms=%s thinking_present=%b thinking_blocks=%d thinking_chars=%d redacted_thinking_blocks=%d thinking_kind=%s"
          turn meta.runtime.usage.total_turns model total_tok context_window
          wall_tok_s prompt_tok_s decode_tok_s cache_n_log prompt_n_log latency_ms
          thinking.thinking_present
          thinking.thinking_blocks
          thinking.thinking_chars
          thinking.redacted_thinking_blocks
          thinking.thinking_kind;
        (* Emit per-turn cost event for task attribution.
           cost_usd from AGENT_CORE Pricing.annotate_response_cost (agent-core boundary resolved). *)
        (match trajectory_acc with
         | Some acc ->
           (* The accumulator's turn counter had no producer, so every
              tool-call entry was written with turn = 0 while reasoning
              entries carried the runtime's real turn. The transcript joins
              trace rows on that number, so a reload found no tool steps for
              any turn and the tool timeline disappeared. Adopt the turn the
              runtime already assigns here; [round] derives from it. *)
           Trajectory.set_turn acc turn;
           emit_cost_event ~masc_root:acc.masc_root
             ~agent_name:meta.name ~task_id:acc.task_id
             ~trace_id ~keeper_turn_id ~agent_core_turn_ordinal:turn ~model
             ~input_tokens:raw_input_tok ~output_tokens:raw_output_tok
             ~cost_usd:cost_usd_for_event ~usage_missing
             ~cache_creation_input_tokens:raw_cache_creation_input_tokens
             ~cache_read_input_tokens:raw_cache_read_input_tokens
             ~usage_trust
             ?telemetry:response.telemetry
             ();
           (* 남김없이: persist THIS turn's reasoning (full, untruncated) every
              turn. The prior single post-run capture (Keeper_agent_run) saved
              only the final turn's thinking; turns 1..N-1 were merely counted
              by the log line above. *)
           Keeper_agent_run_thinking_trajectory.persist_response_content
             ~keeper_name:meta.name ~trajectory_acc:(Some acc) ~turn
             response.content
         | None -> ());
        (try
           (* Cache observability rides the same per-turn event (RFC-0382):
              [cache_read_tokens] is usage-reported (cloud providers),
              [cache_n]/[prompt_n] are wire timings (llama-server, Ollama) —
              KV-reused vs freshly prefilled prompt tokens. The two sources
              have different semantics and are surfaced side by side, never
              merged. *)
           let timings_int_json field =
             match response.telemetry with
             | Some { timings = Some t; _ } ->
               Option.fold ~none:`Null ~some:(fun n -> `Int n) (field t)
             | Some { timings = None; _ } | None -> `Null
           in
           Sse.broadcast
             (`Assoc
               [
                 (key_type, `String sse_turn_observation);
                 ("usage_projection", `String "raw_observation");
                 (key_name, `String meta.name);
                 (key_turn, `Int turn);
                 (key_model_used, `Null);
                 (key_input_tokens, `Int input_tok);
                 (key_output_tokens, `Int output_tok);
                 (key_cost_usd, cost_usd_for_sse);
                 (key_tool_calls_made, `Int !tool_call_count_ref);
                 (key_cache_read_tokens,
                  if usage_missing then `Null
                  else `Int raw_cache_read_input_tokens);
                 (key_cache_n,
                  timings_int_json (fun (t : Agent_core.Types.inference_timings)
                                     -> t.cache_n));
                 (key_prompt_n,
                  timings_int_json (fun (t : Agent_core.Types.inference_timings)
                                     -> t.prompt_n));
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
               "turn=%d sse_turn_observation broadcast failed: %s"
               turn (Printexc.to_string exn));
        tool_call_count_ref := 0;
        Agent_core.Hooks.Continue
      | _event -> Agent_core.Hooks.Continue);

    post_tool_use = Some (fun event ->
      match event with
      | Agent_core.Hooks.PostToolUse
          { invocation
          ; tool_name
          ; input
          ; output
          ; duration_ms = hook_duration_ms
          ; _
          } ->
        record_progress ("tool_completed:" ^ tool_name);
        (* The Answering overlay's live glance: the most recent tool this
           turn ran. Written beside the progress stamp so the two facts
           cannot drift apart. *)
        Keeper_turn_preview.note_tool
          ~keeper_name:(!meta_ref).name
          ~now:(Unix.gettimeofday ())
          (Some tool_name);
        incr tool_call_count_ref;
        (* AGENT_CORE exposes the provider-facing tool body here as text.  It is not a
           semantic authority: JSON-looking bytes must stay opaque.  A future
           typed AGENT_CORE hook field may carry [Keeper_tool_outcome]; until then the
           explicit typed value is unavailable rather than reconstructed from
           content. *)
        let output_text, typed_outcome =
          match output with
          | Ok { Agent_core.Types.content; _ } -> content, None
          | Error { Agent_core.Types.message; _ } -> (message, None)
        in
        let input_keys = tool_input_keys_for_log input in
        let outcome, out_len = match output with
          | Ok { Agent_core.Types.content; _ } -> Tool_result.Ok, String.length content
          | Error { Agent_core.Types.message; _ } -> Tool_result.Error, String.length message
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
        (* [params] carries key names only, which answers what the model
           reached for but not what it asked for. A repository audit could see
           that a gh call failed and not which slug it named, so "the keeper
           invented an org" and "the keeper never ran gh" read the same
           afterwards (#23822). On failure the redacted argument values go
           beside it; a successful call still logs keys only, so the added
           bytes land only where someone is reading back. *)
        let failed_params =
          match output with
          | Ok _ -> "-"
          | Error _ ->
            Observability_redact.redact_json_value input
            |> Yojson.Safe.to_string
            |> one_line_preview_for_log
        in
        (match outcome with
         | Tool_result.Error -> Log.Keeper.error
         | Tool_result.Ok | Tool_result.Unknown -> Log.Keeper.info)
          "keeper:%s tool_call tool=%s source=%s params=[%s] input_shape=[%s] \
           outcome=%s out_len=%d failed_params=%s error_preview=%s"
          (!meta_ref).name
          tool_name
          (* Which file this name's definition was read from. A tool that
             behaved unexpectedly is one an operator wants to open, and the
             record did not say where to look. [-] is a built-in, which ships
             no file — itself the answer. *)
          (match Keeper_tool_definition_source.resolve tool_name with
           | Some rel -> rel
           | None -> "-")
          input_keys
          input_shape
          outcome_s
          out_len
          failed_params
          error_preview;
        (* Agent Core measures duration per invocation. Do not reconstruct it
           from Keeper-global mutable state: sibling calls may overlap. *)
        let duration_ms = hook_duration_ms in
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
        (* Consume truncation info set by keeper_tools_agent_core before returning
           the (possibly truncated) result to AGENT_CORE. Falls back to out_len
           when no truncation info was set (e.g. AGENT_CORE-internal tool calls). *)
        let tool_use_id = Agent_core.Tool_contract.Invocation.tool_use_id invocation in
        let original_bytes, truncated_to =
          Keeper_tool_call_log.consume_truncation_info
            ~invocation
            ()
        in
        let result_bytes = if original_bytes > 0 then original_bytes else out_len in
        (* Full record read: log_call no longer falls back to ambient
           context (RFC-0225 §3.3), so every field this row should carry
           must be passed explicitly from the run's own cell. *)
        let tctx : Keeper_tool_call_log_context.turn_context =
          Keeper_tool_call_log_context.get_turn_context_record
            ~cell:turn_ctx_cell ()
        in
        let invocation_turn = Some (Agent_core.Tool_contract.Invocation.turn invocation) in
        (* RFC-0233 PR-1: one mint per execution at this dispatch boundary;
           the log_call row and the trajectory entry below share the value
           so downstream views can join the two stores on a single key. *)
        let execution_id = Ids.Execution_id.generate () in
        let schedule = Agent_core.Tool_contract.Invocation.schedule invocation in
        (* RFC-0233 PR-2: register the provider-call ↔ execution pair now,
           strictly before AGENT_CORE publishes ToolCompleted for this call, so the
           event bridge can stamp the same id onto the agent_core:tool_completed
           row (insert happens-before publish happens-before drain). *)
        Keeper_execution_join.record ~invocation
          ~execution_id:(Ids.Execution_id.to_string execution_id);
        let log_committed = ref false in
        let file_change_evidence =
          Keeper_tool_call_log.peek_file_change_evidence ~invocation ()
        in
        (* A completed mutation's producer evidence cannot be recoverably
           reconstructed. Supplying [on_committed] forces this row through the
           synchronous append boundary; only that acknowledgement removes the
           invocation-scoped carrier. *)
        let on_log_committed =
          match file_change_evidence, on_tool_result_ready with
          | None, None -> None
          | _ ->
            Some
              (fun () ->
                 log_committed := true;
                 (match file_change_evidence with
                  | Some _ ->
                    ignore
                      (Keeper_tool_call_log.consume_file_change_evidence
                         ~invocation
                         ())
                  | None -> ());
                 Option.iter
                   (fun notify ->
                      notify
                        ~tool_call_id:tool_use_id
                        ~turn:
                          (Agent_core.Tool_contract.Invocation.turn invocation)
                        ~planned_index:schedule.planned_index
                        ~execution_id)
                   on_tool_result_ready)
        in
        (try
           Keeper_tool_call_log.log_call
             ~keeper_name:(!meta_ref).name
             ~tool_name ~input ~output_text
             ~success:(outcome = Tool_result.Ok)
             (* The boolean above is what AGENT_CORE's result can say. The
                typed value crossed from the masc dispatch boundary; without
                it the row cannot tell a policy rejection from a runtime
                failure, and cannot represent [Deferred] at all. *)
             ?disposition:
               (Keeper_tool_call_log.consume_disposition ~invocation ())
             ?file_change_evidence
             ~duration_ms
             ~model:(current_keeper_model !meta_ref)
             ?agent_name:tctx.agent_name
             ?turn_kind:tctx.turn_kind
             ?lane:tctx.lane ?tool_choice:tctx.tool_choice
             ?thinking_enabled:tctx.thinking_enabled
             ?thinking_budget:tctx.thinking_budget
             ?prompt_fingerprint:tctx.prompt_fingerprint
             ~execution_id
             ~tool_use_id
             ~planned_index:schedule.planned_index
             ~batch_index:schedule.batch_index
             ~batch_size:schedule.batch_size
             ~execution_mode:schedule.execution_mode
             ?trace_id:tctx.trace_id ?session_id:tctx.session_id
             ?turn:invocation_turn ?keeper_turn_id:tctx.keeper_turn_id
             ?task_id:tctx.task_id
             ?sandbox_profile:tctx.sandbox_profile
             ?sandbox_root:tctx.sandbox_root
             ?sandbox_roots:tctx.sandbox_roots
             ?network_mode:tctx.network_mode
             ?runtime_profile:tctx.runtime_profile
             ~result_bytes ?truncated_to
             ?on_committed:on_log_committed
             ()
         with
         | Eio.Cancel.Cancelled _ as e ->
             if not !log_committed
             then Keeper_execution_join.discard ~invocation;
             raise e
         | exn ->
             if not !log_committed
             then Keeper_execution_join.discard ~invocation;
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
               tool_name (Printexc.to_string exn);
             if tool_result_commit_required () then raise exn);
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
                 ~producer:"keeper_hooks_agent_core.post_tool_use"
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
        Agent_core.Hooks.Continue
      | _event -> Agent_core.Hooks.Continue);

    on_stop = Some (fun event ->
      match event with
      | Agent_core.Hooks.OnStop { reason; _ } ->
        Otel_metric_store.inc_counter Keeper_metrics.(to_string Agent_coreOnStop)
          ~labels:
            [
              (label_keeper, (!meta_ref).name);
              (label_stop_reason, stop_reason_to_label reason);
            ]
          ();
        Agent_core.Hooks.Continue
      | _event -> Agent_core.Hooks.Continue);

    on_error = Some (function
      | Agent_core.Hooks.OnError { detail; context = err_ctx; _ } ->
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string LifecycleCallbackFailures)
          ~labels:[(label_keeper, (!meta_ref).name); (label_callback, callback_label_on_error)]
          ();
        Log.Keeper.error ~keeper_name:(!meta_ref).name "on_error: %s (context: %s)"
          detail err_ctx;
        Agent_core.Hooks.Continue
      | _event -> Agent_core.Hooks.Continue);

    on_tool_error = Some (function
      | Agent_core.Hooks.OnToolError { tool_name; error; _ } ->
        let keeper_name = (!meta_ref).name in
        (* [OnToolError] carries opaque text but no typed MASC failure class.
           Do not reclassify it by decoding a JSON-looking message. *)
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string LifecycleCallbackFailures)
          ~labels:
            [ (label_keeper, keeper_name)
            ; (label_callback, callback_label_on_tool_error)
            ]
          ();
        (* One tool failure used to leave three operator-facing lines. On
           2026-08-21 all 184 of them carried, for the same call and the same
           public tool name, the richer [keeper:<k> tool_call tool=... params=...
           input_shape=... outcome=error out_len=... error_preview=...] line
           emitted above at Error, and 174 also carried [tool <internal> returned
           error result: ...] from [Keeper_tools_agent_core] — which derives its
           level from the typed failure class, so an expected policy rejection is
           not an Error there. This arm has only opaque text and no failure
           class, so it can neither honour that contract nor add anything the
           other two lack; it hardcoded Error and made a rejection read as a
           fault while double-counting every failure. Its sibling
           [post_tool_use_failure] was demoted for the same reason and left this
           one behind. What keeps this failure on the record is the pair of
           durable JSONL lines above, not the counter: [Otel_metric_store] is
           process memory with no reachable exporter here, so it answers
           nothing after a restart. *)
        Log.Keeper.debug ~keeper_name "tool_error: %s — %s" tool_name error;
        Agent_core.Hooks.Continue
      | _event -> Agent_core.Hooks.Continue);

    post_tool_use_failure = Some (function
      | Agent_core.Hooks.PostToolUseFailure
          { invocation; tool_name; input; stage; duration_ms; error } ->
        let meta = !meta_ref in
        (* The richer counterpart
             "tool <name> returned error result (n/max): <detail>"
           is already emitted at ERROR by keeper_tools_agent_core before this
           hook runs. Emitting a second ERROR here with the same error
           content produces paired duplicate lines per tool failure —
           keep a debug trace for hook-chain readers only. *)
        Log.Keeper.debug ~keeper_name:meta.name "tool_use_failure: %s — %s"
          tool_name error;
        (* #9919: this path is a count event, not a heuristic decision. *)
        record_tool_use_failure ~keeper_name:meta.name ~tool_name;
        (match stage with
         | Agent_core.Hooks.Execution ->
           (* [post_tool_use] fires for this same call and already wrote its
              row. Writing again here would double every executed failure. *)
           ()
         | Agent_core.Hooks.Validation_before_execution ->
           (* The handler never ran, so [post_tool_use] never fires and no
              other site records the call. Until this row existed a rejected
              call left only a counter: the keeper could not see the argument
              object it got refused for, and repeated it. *)
           let tctx : Keeper_tool_call_log_context.turn_context =
             Keeper_tool_call_log_context.get_turn_context_record
               ~cell:turn_ctx_cell ()
           in
           let tool_use_id =
             Agent_core.Tool_contract.Invocation.tool_use_id invocation
           in
           let turn = Agent_core.Tool_contract.Invocation.turn invocation in
           let schedule =
             Agent_core.Tool_contract.Invocation.schedule invocation
           in
           let execution_id = Ids.Execution_id.generate () in
           Keeper_execution_join.record
             ~invocation
             ~execution_id:(Ids.Execution_id.to_string execution_id);
           let log_committed = ref false in
           (try
              Keeper_tool_call_log.log_call
                ~keeper_name:meta.name
                ~tool_name ~input ~output_text:error
                ~success:false ~duration_ms
                ~model:(current_keeper_model meta)
                ?agent_name:tctx.agent_name
                ?turn_kind:tctx.turn_kind
                ?lane:tctx.lane
                ~execution_id
                ~tool_use_id
                ~planned_index:schedule.planned_index
                ~batch_index:schedule.batch_index
                ~batch_size:schedule.batch_size
                ~execution_mode:schedule.execution_mode
                ~turn
                ?trace_id:tctx.trace_id ?session_id:tctx.session_id
                ?keeper_turn_id:tctx.keeper_turn_id
                ?task_id:tctx.task_id
                ~result_bytes:(String.length error)
                ?on_committed:
                  (Option.map
                     (fun notify () ->
                        log_committed := true;
                        notify
                          ~tool_call_id:tool_use_id
                          ~turn
                          ~planned_index:schedule.planned_index
                          ~execution_id)
                     on_tool_result_ready)
                ()
            with
            | Eio.Cancel.Cancelled _ as e ->
              if not !log_committed
              then Keeper_execution_join.discard ~invocation;
              raise e
            | exn ->
              if not !log_committed
              then Keeper_execution_join.discard ~invocation;
              Otel_metric_store.inc_counter
                Keeper_metrics.(to_string LifecycleCallbackFailures)
                ~labels:
                  [ (label_keeper, meta.name)
                  ; (label_callback, callback_label_post_tool_log_write)
                  ]
                ();
              Log.Keeper.warn ~keeper_name:meta.name
                "tool=%s rejected-call log_call write failed: %s"
                tool_name (Printexc.to_string exn);
              if tool_result_commit_required () then raise exn));
        Agent_core.Hooks.Continue
      | _event -> Agent_core.Hooks.Continue);
  }
  in
  hooks

let hook_introspection_json () : Yojson.Safe.t =
  Keeper_hooks_agent_core_introspection.hook_introspection_json ()

module For_testing = struct
  let tool_input_shape_for_log = tool_input_shape_for_log
  let tool_input_keys_for_log = tool_input_keys_for_log
  let cost_usd_json = cost_usd_json
  let usage_missing_of_usage = usage_missing_of_usage
end
