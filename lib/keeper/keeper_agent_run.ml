(** Keeper_agent_run — Run a single keeper turn via OAS Agent.run().

    This module is intentionally a compatibility facade: public types and
    entrypoints stay here while prompt metrics, result/error helpers, and
    tool-surface policy live in focused implementation modules. *)

include Keeper_agent_prompt_metrics
include Keeper_agent_tool_surface
include Keeper_agent_result
include Keeper_agent_error
include Keeper_agent_checkpoint_hygiene
module Contract_helpers = Keeper_agent_run_contract_helpers
module Turn_helpers = Keeper_agent_run_turn_helpers

let per_provider_timeout_for_turn = Turn_helpers.per_provider_timeout_for_turn
let progress_keeper_tool_names_for_contract =
  Contract_helpers.progress_keeper_tool_names_for_contract
;;

let observation_timestamp_ms () =
  (* NDT-OK: wall-clock timestamp for IDE observation telemetry only; keeper
     control flow does not branch on this value. *)
  Int64.of_float (Unix.gettimeofday () *. 1000.0)
;;

let completion_contract_result_for_progress_evidence =
  Turn_helpers.completion_contract_result_for_progress_evidence

let keeper_oas_visibility_neutral_guardrails ?guardrails () =
  let max_tool_calls_per_turn =
    match guardrails with
    | Some guardrails -> guardrails.Agent_sdk.Guardrails.max_tool_calls_per_turn
    | None -> Agent_sdk.Guardrails.default.max_tool_calls_per_turn
  in
  { Agent_sdk.Guardrails.tool_filter = Agent_sdk.Guardrails.AllowAll
  ; max_tool_calls_per_turn
  }
;;

let normalize_response_text_for_finalization
      ~runtime_id
      ~initial_messages
      ~(run_result : Runtime_agent.run_result)
      ~text
      ~tool_names
      ()
  =
  match Keeper_tool_response.normalize_response_text ~text ~tool_names () with
  | Ok response_text -> Ok response_text
  | Error _ ->
    (* Finalization intentionally exposes the higher-level accept-rejected
       error with tool context and raw runtime response. The normalizer error
       only says the response text could not be canonicalized. *)
    let last_tool_context =
      Keeper_turn_driver_try_provider.accept_rejection_context_of_run_result
        ~initial_messages
        run_result
    in
    Error
      (Keeper_turn_driver_try_provider.accept_rejected_error
         ~last_tool_context
         ~runtime_id
         ~response:run_result.response)
;;

(* OAS raw-trace sink for keeper turns: parsed Run_started / Assistant_block /
   Tool_execution / Run_finished records written to a fresh per-turn JSONL
   under [Keeper_types_support.keeper_raw_trace_dir]. Passing the sink into
   [Keeper_turn_driver.run_named] is what populates
   [run_result.trace_ref]/[run_validation] for the unified-metrics consumers
   and the progress-evidence gate.

   Failure isolation: the trace store is observability state and must never
   gate keeper liveness. A fresh file per turn keeps [Raw_trace.create]
   (OAS [create -> scan_next_seq -> read_all]) from parsing any previous
   turn's data, so a corrupt or oversized historical trace cannot wedge
   dispatch — and if sink creation still fails, the turn dispatches
   untraced with the typed [Sink_degraded] record emitted as a warn log
   plus the [Keeper_metrics.RawTraceSinkDegraded] counter. *)
type raw_trace_sink_outcome =
  | Sink_ready of Agent_sdk.Raw_trace.t
  | Sink_degraded of Agent_sdk.Error.sdk_error

let keeper_raw_trace_sink
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
  : raw_trace_sink_outcome
  =
  (* Path derivation ensures [.masc/keepers/<name>/raw-traces/]; any
     filesystem refusal (unwritable parent, blocked path) must land in
     [Sink_degraded], not escape into the turn. *)
  let path_result =
    try Ok (Keeper_types_support.keeper_raw_trace_turn_path config meta.name)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Agent_sdk.Error.Internal (Printexc.to_string exn))
  in
  match path_result with
  | Error err -> Sink_degraded err
  | Ok path ->
    (match
       Agent_sdk.Raw_trace.create
         ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
         ~path
         ()
     with
     | Ok sink ->
       let (_removed : int) =
         Keeper_types_support.prune_keeper_raw_trace_turn_files
           config
           meta.name
       in
       Sink_ready sink
     | Error err -> Sink_degraded err)
;;

(* Dispatch adapter: a degraded sink means the turn runs untraced
   ([trace_ref]/[run_validation] stay [None] for that turn), never that
   the turn fails pre-dispatch. The degrade is typed and observable:
   warn log + [RawTraceSinkDegraded] counter labelled by keeper. *)
let raw_trace_for_dispatch
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
  : Agent_sdk.Raw_trace.t option
  =
  match keeper_raw_trace_sink ~config ~meta with
  | Sink_ready sink -> Some sink
  | Sink_degraded err ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string RawTraceSinkDegraded)
      ~labels:[ "keeper", meta.name ]
      ();
    Log.Keeper.warn ~keeper_name:meta.name
      "raw-trace sink degraded; dispatching turn untraced: %s"
      (Agent_sdk.Error.to_string err);
    None
;;

module For_testing = struct
  let sse_event_progress_kind = Turn_helpers.sse_event_progress_kind
  let sse_event_watchdog_progress_kind =
    Turn_helpers.sse_event_watchdog_progress_kind
  let registry_progress_on_event = Turn_helpers.registry_progress_on_event
  let progress_keeper_tool_names_for_contract =
    Contract_helpers.progress_keeper_tool_names_for_contract
  let keeper_oas_visibility_neutral_guardrails =
    keeper_oas_visibility_neutral_guardrails
  let normalize_response_text_for_finalization =
    normalize_response_text_for_finalization
  let keeper_raw_trace_sink = keeper_raw_trace_sink
  let raw_trace_for_dispatch = raw_trace_for_dispatch
end

(** Run a single keeper turn via OAS Agent.run().

    Loads checkpoint, creates working context with the base keeper system
    prompt, then calls [build_turn_prompt] with the base prompt and message
    history so the caller can layer skill routing, continuity context,
    policy guards, and turn-specific instructions on top.

    After the callback returns the final system prompt, appends the user
    message, builds OAS tools + hooks, and delegates to
    [Keeper_turn_driver.run_named] which internally calls Agent.run().

    @param config Workspace configuration
    @param meta Keeper metadata
    @param base_dir Session base directory for checkpoints
    @param max_context Maximum context window tokens
     @param build_turn_prompt Callback: receives the base keeper system prompt
            and checkpoint message history, returns the final turn system prompt
     @param user_message The user's message to the keeper
    @param runtime_id Runtime profile name for model selection
     @param generation Current generation counter
     @param guardrails Optional OAS guardrails for tool safety gates
    @param temperature MODEL temperature override; when omitted, resolved
           from [Runtime_inference] with a 0.3 fallback
    @param max_tokens Maximum output tokens override; when omitted, resolved
           from [Runtime_inference] with a 8192 fallback
    @param is_retry When [true], replays the current user message into the
           working context without persisting it again, so transient retry
           attempts do not duplicate the user entry in session history *)
let run_turn
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(turn_ctx_cell : Keeper_tool_call_log.turn_ctx_cell)
      ~(base_dir : string)
      ~(max_context : int)
      ~(build_turn_prompt :
         base_system_prompt:string -> messages:Agent_sdk.Types.message list -> turn_prompt)
      ~(user_message : string)
      ?user_blocks
      ~(runtime_id : string)
      ?world_observation
      ?(turn_affordances = [])
      ~(generation : int)
      ~(max_idle_turns : int)
      (* Required, no default: the OAS loop guard kills the run at this
         count, so the caller must pick the channel-appropriate threshold
         (reactive/autonomous). A silent default of 3 sat below the
         graduated idle hook's skip threshold (4), making graceful Skip
         unreachable — user chat turns died as IdleDetected errors. *)
      ?(history_user_source = "direct_user")
      ?(history_assistant_source = "direct_assistant")
      ?guardrails
      ?temperature
      ?max_tokens
      ?oas_timeout_s
      ?(oas_timeout_is_explicit = true)
      ?on_event
      ?(trajectory_acc : Trajectory.accumulator option)
      ?(tool_overlay : Agent_sdk.Tool_op.t ref option)
      ?priority
      ?(degraded_retry_applied = false)
      ?degraded_retry_runtime
      ?fallback_reason
      ?(runtime_rotation_attempts = [])
      ?(is_retry = false)
      ?shared_context
      ?event_bus
      ?trace_link
      ?continuation_channel
      ?yield_to_chat_waiting
      ()
  : (run_result, Agent_sdk.Error.sdk_error) result
  =
  (* Section 1: Setup — sanitize input, build context, compose prompt. *)
  let user_message = Keeper_run_prompt.sanitize_user_message user_message in
  Masc_runtime_events.emit_turn_start ();
  let partition, _ =
    Keeper_tool_filesystem_runtime.resolve_partition_for_write
      ~base_dir:config.base_path ~kind:"turn_event" ~file_path:config.base_path
  in
  Agent_observation.emit_turn_event
    { base_path = config.base_path
    ; partition
    ; turn_id =
        (match meta.current_task_id with
         | Some t -> Keeper_id.Task_id.to_string t
         | None -> "turn-" ^ meta.name)
    ; keeper_id = meta.name
    ; phase = "started"
    ; model_used = None
    ; tools_used = []
    ; stop_reason = None
    ; duration_ms = None
    ; timestamp_ms = observation_timestamp_ms ()
    };
  (* Cancel-safe cleanup (#9747): [Eio_guard.protect] already uses
     [Eio.Switch.on_release], so cleanup runs under cooperative cancellation
     and does not mask the outer [Eio.Cancel.Cancelled]. We still need to
     preserve the *terminal state* through the finally block: a cancelled
     turn must emit phase="cancelled" in the observation event so receipts
     and registry consumers agree with the FSM terminal [Cancelled _].
     The [turn_cancelled] ref is set only when the turn body actually raises
     [Eio.Cancel.Cancelled]; the finally block inspects it to pick the
     observation phase. *)
  let turn_start_time = Unix.gettimeofday () in
  let turn_cancelled = ref None in
  let emit_observation_turn_end ~phase ~stop_reason () =
    let duration_ms = int_of_float ((Unix.gettimeofday () -. turn_start_time) *. 1000.0) in
    let turn_id = match meta.current_task_id with Some t -> Keeper_id.Task_id.to_string t | None -> "turn-" ^ meta.name in
    let partition, _ =
      Keeper_tool_filesystem_runtime.resolve_partition_for_write
        ~base_dir:config.base_path ~kind:"turn_event" ~file_path:config.base_path
    in
    Agent_observation.emit_turn_event
      { base_path = config.base_path
      ; partition
      ; turn_id
      ; keeper_id = meta.name
      ; phase
      ; model_used = None
      ; tools_used = []
      ; stop_reason
      ; duration_ms = Some duration_ms
      ; timestamp_ms = observation_timestamp_ms ()
      }
  in
  let safe_emit_turn_end () =
    let phase, stop_reason =
      match !turn_cancelled with
      | Some exn -> "cancelled", Some (Printexc.to_string exn)
      | None -> "completed", None
    in
    (try emit_observation_turn_end ~phase ~stop_reason ()
     with Eio.Cancel.Cancelled _ as ce -> raise ce
     | exn ->
       Log.Keeper.warn "keeper:%s emit_observation_turn_end failed: %s"
         meta.name (Printexc.to_string exn));
    Turn_helpers.emit_turn_end_safely ~keeper_name:meta.name ()
  in
  Eio_guard.protect ~finally:safe_emit_turn_end
  @@ fun () ->
  try
  (* RFC-0107 §3.3 Phase C.1 wiring — turn-scoped Eio.Switch.
     Resources opened during a turn (HTTP connections, sandbox exec
     handles, retry sub-tasks via [Keeper_turn_driver_try_provider])
     that read [Eio_context.get_switch_opt ()] now attach to [turn_sw],
     not the server root_sw. When this [Eio.Switch.run] closes (turn
     end, success or cancellation), those resources are released —
     bounding per-turn FD growth.

     Server/dashboard fibers that read [get_switch_opt] from *outside*
     this binding are unaffected (audit §10.2): they have no
     [Eio.Fiber] binding for [sw_key], so [get_switch_opt] falls
     through to the global atomic = server root_sw.

     The [with_turn_switch] binding propagates with [Eio.Fiber.fork]
     children, so runtime attempts and tool invocations spawned inside
     the turn body all see [turn_sw] automatically. *)
  Eio.Switch.run @@ fun turn_sw ->
  Eio_context.with_turn_switch turn_sw
  @@ fun () ->
  let runtime_id_string = runtime_id in
  (* Steps 0–4: inference params, session dir, checkpoint, base prompt,
     working context, checkpoint hygiene — all in Keeper_run_context. *)
  let ctx =
    Keeper_run_context.prepare_run_context
      ~config
      ~meta
      ~base_dir
      ~max_context
      ~runtime_id
      ?temperature
      ?max_tokens
      ?shared_context
      ~generation
      ()
  in
  let requested_max_tokens = max_tokens in
  let meta = ctx.meta in
  let temperature = ctx.temperature in
  let max_output_ceiling =
    None
  in
  let max_tokens, pre_dispatch_max_tokens_error =
    match
      Runtime_inference.validate_max_tokens_within_ceiling
        ~runtime_id
        ~provider_ceiling:max_output_ceiling
        ctx.max_tokens
    with
    | Ok max_tokens -> max_tokens, None
    | Error internal_error ->
      let detail =
        Option.value
          ~default:(Keeper_internal_error.kind_of_masc_internal_error internal_error)
          (Keeper_internal_error.summary_of_masc_internal_error internal_error)
      in
      Log.Keeper.error "%s: %s" meta.name detail;
      ( ctx.max_tokens,
        Some (Keeper_internal_error.sdk_error_of_masc_internal_error internal_error) )
  in
  let context_injector = ctx.context_injector in
  let shared_context = ctx.shared_context in
  let session = ctx.session in
  let base_system_prompt = ctx.base_system_prompt in
  let resume_oas_checkpoint = ctx.resume_oas_checkpoint in
  let pre_dispatch_compacted = ctx.pre_dispatch_compacted in
  let pre_dispatch_checkpoint_error = ctx.pre_dispatch_checkpoint_error in
  let start_turn_count = ctx.start_turn_count in
  let receipt_started_at = ctx.receipt_started_at in
  let config_root = ctx.config_root in
  let runtime_config_path = ctx.runtime_config_path in
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let manifest_keeper_turn_id = meta.runtime.usage.total_turns + 1 in
  let turn_start = Mtime_clock.now () in
  let seq_ref = Atomic.make 0 in
  let runtime_manifest_context =
    Turn_helpers.runtime_manifest_context
      ~keeper_name:meta.name
      ~agent_name:meta.agent_name
      ~trace_id
      ~generation
      ~keeper_turn_id:manifest_keeper_turn_id
  in
  let checkpoint_path =
    Keeper_checkpoint_store.oas_checkpoint_path ~session_dir:session.session_dir
      ~session_id:trace_id
  in
  let append_manifest =
    Turn_helpers.make_append_manifest
      ~config
      ~keeper_name:meta.name
      ~agent_name:meta.agent_name
      ~trace_id
      ~generation
      ~runtime_id:runtime_id_string
      ~turn_start
      ~seq_ref
  in
  let digest_text = Turn_helpers.digest_text in
  let digest_message_texts_as_joined =
    Turn_helpers.digest_message_texts_as_joined
  in
  append_manifest ~site:"checkpoint_loaded"
    ~keeper_turn_id:manifest_keeper_turn_id
    ~checkpoint_path
    ~decision:
      (Keeper_runtime_manifest.with_payload_role ~payload_role:Checkpoint
        (`Assoc
          [
            ("loaded_checkpoint_present", `Bool ctx.loaded_checkpoint_present);
            ("pre_dispatch_compacted", `Bool pre_dispatch_compacted);
            ( "pre_dispatch_checkpoint_error",
              match pre_dispatch_checkpoint_error with
              | None -> `Null
              | Some err -> `String (Agent_sdk.Error.to_string err) );
          ]))
    Keeper_runtime_manifest.Checkpoint_loaded;
  append_manifest ~site:"context_compacted"
    ~keeper_turn_id:manifest_keeper_turn_id
    ?compaction_source:
      (if pre_dispatch_compacted then Some "pre_dispatch_hygiene" else None)
    ~status:(if pre_dispatch_compacted then "compacted" else "skipped")
    ~decision:
      (Keeper_runtime_manifest.with_payload_role ~payload_role:Model_input
        (`Assoc
          [
            ("pre_dispatch_compacted", `Bool pre_dispatch_compacted);
            ( "pre_dispatch_checkpoint_error",
              match pre_dispatch_checkpoint_error with
              | None -> `Null
              | Some err -> `String (Agent_sdk.Error.to_string err) );
            ("checkpoint_path", `String checkpoint_path);
          ]))
    Keeper_runtime_manifest.Context_compacted;
  (* Steps 5-6: turn prompt, memory/temporal context, prompt metrics,
     user message append, token estimation — Keeper_run_prompt. *)
  let prompt_ctx =
    Keeper_run_prompt.build_turn_context
      ~ctx
      ~build_turn_prompt
      ~user_message
      ~config
      ~meta
      ~history_user_source
      ~is_retry
      ~start_turn_count
  in
  let turn_system_prompt = prompt_ctx.Keeper_run_prompt.turn_system_prompt in
  let dynamic_context = prompt_ctx.Keeper_run_prompt.dynamic_context in
  let memory_context = prompt_ctx.Keeper_run_prompt.memory_context in
  let temporal_context = prompt_ctx.Keeper_run_prompt.temporal_context in
  let prompt_metrics = prompt_ctx.Keeper_run_prompt.prompt_metrics in
  let history_messages = prompt_ctx.Keeper_run_prompt.history_messages in
  let estimated_input_tokens = prompt_ctx.Keeper_run_prompt.estimated_input_tokens in
  let ctx_work = prompt_ctx.Keeper_run_prompt.ctx_work in
  let history_messages_digest = digest_message_texts_as_joined history_messages in
  let context_digest =
    digest_text
      (base_system_prompt ^ turn_system_prompt ^ dynamic_context ^ memory_context
       ^ temporal_context ^ user_message ^ history_messages_digest)
  in
  append_manifest ~site:"context_injected"
    ~keeper_turn_id:manifest_keeper_turn_id
    ~decision:
      (Keeper_runtime_manifest.with_payload_role ~payload_role:Model_input
        (`Assoc
          [
            ("base_system_prompt_digest", `String (digest_text base_system_prompt));
            ("turn_system_prompt_digest", `String (digest_text turn_system_prompt));
            ("dynamic_context_digest", `String (digest_text dynamic_context));
            ("memory_context_digest", `String (digest_text memory_context));
            ("temporal_context_digest", `String (digest_text temporal_context));
            ("user_message_digest", `String (digest_text user_message));
            ("history_message_count", `Int (List.length history_messages));
            ("history_messages_digest", `String history_messages_digest);
            ("estimated_input_tokens", `Int estimated_input_tokens);
            ("context_window", `Int max_context);
            ("context_digest", `String context_digest);
          ]))
    Keeper_runtime_manifest.Context_injected;
  (* 7. Set up agent — delegated to Keeper_run_tools *)
  let setup =
    Keeper_run_tools.prepare_agent_setup
      ~config
      ~meta
      ~turn_ctx_cell
      ~ctx_work
      ~session
      ~base_system_prompt
      ~turn_system_prompt
      ~user_message
      ~dynamic_context
      ~history_messages
      ~prompt_metrics
      ~estimated_input_tokens
      ~max_context
      ~shared_context
      ~context_injector
      ~start_turn_count
      ~generation
      ~runtime_id
      ~is_retry
      ~turn_affordances
      ~config_root
      ~runtime_config_path
      ~trajectory_acc
      ~tool_overlay
      ~runtime_manifest_context
      ~runtime_manifest_append:
        (fun manifest ->
           Keeper_runtime_manifest.append_best_effort
             ~site:"context_injection_hook"
             config
             manifest)
      ()
  in
  (* Section 2: prepare runtime tools and hooks. *)
  match setup with
  | Error e -> Error e
  | Ok s ->
    let cleanup_agent_setup () =
      Turn_helpers.cleanup_agent_setup ~keeper_name:meta.name s
    in
    Turn_helpers.run_with_setup_cleanup ~cleanup:cleanup_agent_setup
    @@ fun () ->
    let tools = s.Keeper_run_tools.tools in
    let tool_context_estimate =
      s.Keeper_run_tools.tool_context_estimate
    in
    let context_window_budget =
      Keeper_run_prompt.context_window_budget
        ~estimated_input_tokens:
          tool_context_estimate.estimated_input_tokens_with_tools
        ~max_context
    in
    (* Pre-dispatch context-window estimate is intentionally observational:
       the definitive ledger includes [extra_system_context] injected by
       [before_turn_params] hooks, which has not run yet. If the request is
       still over budget after hooks, we rely on the OAS/driver's
       [oas_auto_context_overflow_retry] path to compact and retry rather
       than hard-failing here and bypassing that recovery path. *)
    let pre_dispatch_context_window_error =
      match
        Keeper_run_prompt.preflight_context_window
          ~estimated_input_tokens:
            tool_context_estimate.estimated_input_tokens_with_tools
          ~max_context
      with
      | Ok () -> None
      | Error err -> Some err
    in
    let context_layer policy text =
      Keeper_run_prompt.estimate_context_layer_policy_budget
        ~max_context
        ~policy
        ~text
    in
    let context_layers =
      [ context_layer
          Keeper_run_prompt.world_dynamic_context_layer_policy
          dynamic_context
      ; context_layer Keeper_run_prompt.memory_context_layer_policy memory_context
      ; context_layer
          Keeper_run_prompt.temporal_context_layer_policy
          temporal_context
      ; context_layer
          Keeper_run_prompt.user_message_context_layer_policy
          user_message
      ]
    in
    append_manifest ~site:"context_preflight"
      ~keeper_turn_id:manifest_keeper_turn_id
      ~status:
        (if Option.is_some pre_dispatch_context_window_error
         then "over_context_window_observed"
         else "ok")
      ~decision:
        (Keeper_runtime_manifest.with_payload_role ~payload_role:Model_input
          (`Assoc
            [
              ( "prompt_estimated_input_tokens",
                `Int estimated_input_tokens );
              ( "tool_count",
                `Int tool_context_estimate.tool_count );
              ( "tool_schema_estimated_tokens",
                `Int tool_context_estimate.tool_schema_tokens );
              ( "estimated_input_tokens_with_tools",
                `Int tool_context_estimate.estimated_input_tokens_with_tools );
              ("context_window", `Int max_context);
              ( "remaining_context_tokens",
                `Int context_window_budget.remaining_context_tokens );
              ( "over_context_tokens",
                `Int context_window_budget.over_context_tokens );
              ( "context_usage_ratio",
                `Float context_window_budget.context_usage_ratio );
              ( "context_layers",
                `List
                  (List.map
                     Keeper_run_prompt.context_layer_budget_to_json
                     context_layers) );
              ( "pre_dispatch_over_context_window",
                `Bool
                  (Option.is_some pre_dispatch_context_window_error) );
            ]))
      Keeper_runtime_manifest.Context_injected;
    let hooks = s.Keeper_run_tools.hooks in
    let reducer = s.Keeper_run_tools.reducer in
    let acc = s.Keeper_run_tools.acc in
    let agent_ref : Agent_sdk.Agent.t option ref = ref None in
    let receipt_turn_count_ref = s.Keeper_run_tools.receipt_turn_count_ref in
    let receipt_model_used_ref = s.Keeper_run_tools.receipt_model_used_ref in
    let receipt_stop_reason_ref = s.Keeper_run_tools.receipt_stop_reason_ref in
    let receipt_runtime_observation_ref =
      s.Keeper_run_tools.receipt_runtime_observation_ref
    in
    let receipt_response_text_present_ref =
      s.Keeper_run_tools.receipt_response_text_present_ref
    in
    let keeper_has_owned_active_task () =
      Option.is_some (owned_active_task_id_for_meta ~config ~meta:acc.meta)
    in
    (* A claim tool mutates [acc.meta.current_task_id_id] during this run; contract
     gating must judge claim-context tools against ownership at turn entry. *)
    let had_owned_active_task_at_turn_start = keeper_has_owned_active_task () in
    (* 8. Run Agent *)
    let record_turn_progress, yield_on_tool, on_yield, on_resume, on_event =
      Turn_helpers.turn_progress_callbacks
        ~config
        ~keeper_name:meta.name
        ~downstream:on_event
        ~turn_id:manifest_keeper_turn_id
    in
    let priority =
      Option.value priority ~default:Llm_provider.Request_priority.Proactive
    in
    ignore (Keeper_alerting_path.ensure_sandbox_bundle ~config ~meta);
    let _keeper_sandbox_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
    let keeper_visible_sandbox_root =
      Keeper_sandbox.keeper_visible_root_abs_of_meta ~config meta
    in
    let effective_allowed_paths = Keeper_alerting_path.effective_allowed_paths ~meta in
    (match
       Keeper_alerting_path.absolute_allowed_paths_result
         ~config
         ~allowed_paths:effective_allowed_paths
     with
     | Error e -> Error (Agent_sdk.Error.Internal e)
     | Ok oas_allowed_paths ->
       let timeout_s =
         match oas_timeout_s with
         | Some value -> value
         | None -> Keeper_runtime_resolved.oas_call_timeout_sec ()
       in
       let per_provider_timeout_s = None in
       (* OAS [stream_idle_timeout_s] bounds inter-line idle on HTTP streams
       (Anthropic/OpenAI/Gemini/GLM/Ollama). The deadline resets after each
       successful line, so this is gap detection, not total run cap.

       Default 120 s catches real network/stream hangs while preserving
       legitimate reasoning pauses + provider keepalives. If the total
       OAS timeout is shorter, the idle gap is clamped to that total cap
       so the nested timeout envelope is explicit. *)
       let stream_idle_timeout_s =
         Some
           (Keeper_runtime_resolved.stream_idle_timeout_for_total_timeout
              ~total_timeout_s:timeout_s)
       in
       Keeper_agent_run_phase0_telemetry.record_if_enabled
         ~meta
         ~turn_system_prompt
         ~tools
         ~history_messages
         ~user_message
         ~start_turn_count
         ~max_context
         ~pre_dispatch_compacted;
       (* Section 3: Dispatch — call Keeper_turn_driver.run_named / Agent.run. *)
       let pre_dispatch_error =
         match pre_dispatch_checkpoint_error with
         | Some err -> Some err
         | None -> pre_dispatch_max_tokens_error
       in
       let turn_result =
         match pre_dispatch_error with
         | Some err -> Error err
         | None ->
              let keeper_oas_guardrails =
                keeper_oas_visibility_neutral_guardrails ?guardrails ()
              in
              let max_tokens_for_runtime ~runtime_id =
                Keeper_run_context.resolve_max_tokens_for_runtime
                  ~keeper_name:meta.name
                  ~runtime_id
                  ?max_tokens:requested_max_tokens
                  ()
              in
              (* Autonomous chat-yield: when the caller supplies
                 [yield_to_chat_waiting], evaluate it at each OAS agent-loop turn
                 boundary (the [check_loop_guard] point, beside [max_idle_turns],
                 before the next model dispatch — never mid tool execution). A
                 [true] result stops the loop; [runtime_agent] converts that stop
                 into a graceful [Ok] result *only* when [exit_condition_result]
                 is also present, so both are wired together — otherwise the SDK
                 [ExitConditionMet] surfaces as an error and the yield would be
                 recorded as a turn failure/blocker. The rendered stop reason is
                 [Yielded_to_chat_waiting], whose disposition is a
                 [Continuation_checkpoint] (like [MutationBoundaryReached]):
                 "stopped early, checkpoint saved, resume next cycle". *)
              let chat_yield_exit_condition, chat_yield_exit_condition_result =
                match yield_to_chat_waiting with
                | None -> None, None
                | Some pred ->
                  ( Some (fun (_turn : int) -> pred ())
                  , Some
                      (fun (turn : int) ->
                        ( Runtime_agent.Yielded_to_chat_waiting { turns_used = turn }
                        , Some
                            (Printf.sprintf
                               "[yielded turn slot at turn %d to a waiting chat \
                                request; keeper resumes on the next cycle]"
                               turn) )) )
              in
              let call_run_named ?raw_trace ~initial_messages () =
                (* The keeper turn deadline must own the OAS Agent.run switch.
                   Stream/body idle budgets catch liveness gaps; this hard
                   ceiling is the final guard that releases a stuck turn slot. *)
	                Keeper_turn_driver.run_named
	                  ~runtime_id:runtime_id_string
	                  ~base_path:config.base_path
	                    ~keeper_name:meta.name
                    ~goal:user_message
                    ?goal_blocks:user_blocks
                    ~priority
                    ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                    ?raw_trace
                    ~system_prompt:turn_system_prompt
                    ~tools
                    ~compact_ratio:meta.compaction.ratio_gate
                    ~context_window_tokens:max_context
                    ~oas_auto_context_overflow_retry:true
                    ~initial_messages
                    ~hooks
                    ~context_reducer:reducer
                   ~summarizer:Keeper_summarizer.keeper_summarizer
                   ~runtime_manifest_context
                   ~runtime_manifest_append:
                     (fun manifest ->
                        Keeper_runtime_manifest.append_best_effort
                          ~site:"runtime_runtime"
                          config
                          manifest)
                      (* No code-level tool-retry budget. Retrying a malformed
              tool call (e.g. missing required arg) is the keeper's own
              competence: the SDK delivers the validation error back to the
              model (pipeline [None] branch) and the agent loop decides whether
              to re-emit. Runaway is bounded by max_idle_turns + token budget,
              not a retry count that halts the turn. *)
                    ~max_idle_turns
                    ?stream_idle_timeout_s
                    ~body_timeout_s:timeout_s
                    ~temperature
                    ~max_tokens
                    ~max_tokens_for_runtime
                    ~accept:
                      Keeper_tool_response.response_has_text_or_tool_progress
                    ~guardrails:keeper_oas_guardrails
                    ?on_event
                    ?on_yield
                    ?on_resume
                    ~agent_ref
                    ~allowed_paths:oas_allowed_paths
                    ~cache_system_prompt:true
                    ~yield_on_tool
                    ~context_injector
                    ~context:shared_context
                    ~approval:
                      (Governance_pipeline.to_oas_approval_callback
                         ~config
                         ~governance_level:(Env_config_core.governance_level ())
                         ~keeper_name:meta.name
                         ~meta
                         ?continuation_channel
                         ?clock:(Eio_context.get_clock_opt ())
                         ())
                    ~enable_thinking:(Keeper_config.keeper_enable_thinking ())
                      (* Mutation-boundary is native to OAS now; [exit_condition]
                         is re-wired here solely for the autonomous chat-yield
                         (see [chat_yield_exit_condition] above). Both are [None]
                         on the chat lane, so a chat turn runs to natural
                         completion (model end_turn) unchanged. *)
                    ?exit_condition:chat_yield_exit_condition
                    ?exit_condition_result:chat_yield_exit_condition_result
                    ?oas_checkpoint:resume_oas_checkpoint
                    ?event_bus
                    ?trace_link
                    ~on_runtime_observation:
                      (fun observation ->
                         receipt_runtime_observation_ref := Some observation)
                    ?per_provider_timeout_s
                    ()
              in
              (* Trace-store failure isolation: [raw_trace_for_dispatch]
                 degrades to [None] (turn runs untraced, typed record
                 emitted) — sink trouble never fails the turn pre-dispatch. *)
              (match
                 call_run_named
                   ?raw_trace:(raw_trace_for_dispatch ~config ~meta)
                   ~initial_messages:history_messages
                   ()
               with
               | Error e -> Error e
               | Ok result ->
                 let post_turn_t0 = Time_compat.now () in
                 (* Checkpoint save is deferred until after [STATE] synthesis so the
           persisted checkpoint includes the synthesized continuity block.
           Without this, read_continuity_summary finds no [STATE] in the
           checkpoint messages and returns empty — causing keepers to lose
           context across turns.  See #5431. *)
                 (* Section 4: Result processing — parse response, handle tool calls, validate contracts. *)
                (* RFC-MASC-004: AfterTurn hooks flush incrementally during
          Agent.run. Post-run episode creation requires an explicit
          flush_incremental call since AfterTurn already fired. *)
                 let text = Agent_sdk.Types.text_of_content result.response.content in
                 (* RFC-0132 PR-2: receipt model surface = external boundary; redact via SSOT. *)
                 let model =
                   Boundary_redaction.to_string
                     Boundary_redaction.runtime_model_label
                 in
                 receipt_turn_count_ref := Some result.turns;
                 receipt_model_used_ref := Some model;
                 receipt_stop_reason_ref := Some result.stop_reason;
                 receipt_runtime_observation_ref := result.runtime_observation;
                 (* Thinking is now persisted per-turn inside the after_turn
                    hook (Keeper_hooks_oas), untruncated, for EVERY turn. The
                    old post-run single-shot capture here saved only the final
                    turn's reasoning and would double-write the terminal turn
                    now, so it was removed. *)
                 let actual_keeper_tool_names =
                   Keeper_agent_result.tool_names_of_calls (List.rev acc.tool_calls)
                 in
                 let progress_keeper_tool_names =
                   progress_keeper_tool_names_for_contract
                     ~actual_keeper_tool_names
                     ~tool_calls:acc.tool_calls
                 in
                 let usage = Keeper_context_runtime.usage_of_response result.response in
                 let ctx_composition =
                   build_ctx_composition_metrics
                     ~system_prompt:turn_system_prompt
                     ~dynamic_context
                     ~memory_context
                     ~temporal_context
                     ~user_message
                     ~history_messages
                     ~actual_input_tokens:(Some usage.input_tokens)
                 in
                 let completion_contract_status ()
                     : Keeper_execution_receipt.completion_contract_result =
                   Contract_helpers.observed_completion_contract_status
                     ~had_owned_active_task_at_turn_start
                     ~actual_keeper_tool_names:progress_keeper_tool_names
                     ~stop_reason:result.stop_reason
                     ~response_text_present:(String.trim text <> "")
                 in
                 let contract_status = completion_contract_status () in
                 acc.receipt_completion_contract_result <- contract_status;
                 (* Root B (#22710): capture the world-observation actionable
                    signal alongside the contract status so the receipt carries
                    the real "is there anything to do" signal. [operator_disposition]
                    uses it to replace the [goal_ids = []] proxy. [None] when no
                    observation was threaded (disposition stays broadcast-required;
                    conservative). *)
                 acc.receipt_actionable_signal <-
                   Option.map
                     (fun obs ->
                       Keeper_contract_classifier.classify_actionable_signal
                         (Keeper_contract_classifier.of_keeper_world_observation obs))
                     world_observation;
                     (match
                        normalize_response_text_for_finalization
                          ~runtime_id:runtime_id_string
                          ~initial_messages:history_messages
                          ~run_result:result
                          ~text
                          ~tool_names:actual_keeper_tool_names
                          ()
                      with
                      | Error e -> Error e
                      | Ok response_text ->
                        Keeper_agent_run_finalize_response.finalize
                          ~config ~meta ~generation ~manifest_keeper_turn_id
                          ~trace_id ~session ~append_manifest ~model
                          ~acc
                          ~actual_keeper_tool_names
                          ~result ~checkpoint_persistence_error
                          ~post_turn_t0 ~runtime_id_string
                          ~history_messages
                          ~pre_turn_working_context:
                            ctx_work.checkpoint.Agent_sdk.Checkpoint.working_context
                          ~prompt_metrics ~ctx_composition ~usage
                          ~receipt_response_text_present_ref ~history_assistant_source
                          ~pre_dispatch_compacted:ctx.pre_dispatch_compacted
                          ~pre_dispatch_compaction_trigger:ctx.pre_dispatch_compaction_trigger
                          ~pre_dispatch_compaction_before_tokens:ctx.pre_dispatch_compaction_before_tokens
                          ~pre_dispatch_compaction_after_tokens:ctx.pre_dispatch_compaction_after_tokens
                          ~raw_response_text:response_text
                          ~capture_replay_response:
                            (fun ~response_text ->
                              (* Phase O observability: capture the exact
                                 assistant text persisted for next-turn replay,
                                 after response finalization has applied
                                 suppression and internal-markup stripping. The
                                 capture is best-effort and gated by
                                 MASC_KEEPER_WIRE_CAPTURE. *)
                              Keeper_wire_capture.capture_response
                                ~masc_root:(Workspace.masc_root_dir config)
                                ~keeper_name:meta.name
                                ~turn_id:manifest_keeper_turn_id
                                ~sdk_turn:result.turns
                                ~trace_id:meta.runtime.trace_id
                                ~response_text
                                ())
                          ()))
               in
       let receipt_result =
         Keeper_agent_run_receipt.finalize
           ~config
           ~meta
           ~generation
           ~manifest_keeper_turn_id
           ~runtime_id
           ~keeper_visible_sandbox_root
           ~receipt_started_at
           ~runtime_manifest_context
           ~acc
           ~pre_dispatch_compacted
           ~pre_dispatch_compaction_trigger:ctx.pre_dispatch_compaction_trigger
           ~pre_dispatch_compaction_before_tokens:ctx.pre_dispatch_compaction_before_tokens
           ~pre_dispatch_compaction_after_tokens:ctx.pre_dispatch_compaction_after_tokens
           ~degraded_retry_applied
           ~degraded_retry_runtime
           ~fallback_reason
           ~runtime_rotation_attempts
           ~turn_result
           ~receipt_turn_count_ref
           ~receipt_model_used_ref
           ~receipt_stop_reason_ref
           ~receipt_runtime_observation_ref
           ~receipt_response_text_present_ref
           ()
       in
       (* RFC-0233 PR-3: TurnRecord — same per-keeper-turn cadence as the
          receipt above. execution_ids come from the trajectory
          accumulator (every entry of this run carries the id minted at
          the dispatch boundary); sampling reads the last SDK turn's
          effective values from the turn context cell. *)
       (let tctx =
          Keeper_tool_call_log_context.get_turn_context_record
            ~cell:turn_ctx_cell ()
        in
        let execution_ids =
          match trajectory_acc with
          | None -> []
          | Some tacc ->
            (* entries are prepended on record; rev restores call order *)
            List.rev
              (List.filter_map
                 (fun (e : Trajectory.tool_call_entry) ->
                    Option.map Ids.Execution_id.of_string e.execution_id)
                 tacc.Trajectory.entries)
        in
        let usage : Turn_record.usage =
          match turn_result with
          | Ok result when result.usage_reported ->
            { input_tokens = Some result.usage.input_tokens
            ; output_tokens = Some result.usage.output_tokens
            }
          | Ok _ | Error _ -> { input_tokens = None; output_tokens = None }
        in
        let request_latency_ms : int option =
          (* RFC-0233 §9 — wall-clock duration of the provider call in
             milliseconds, sourced from OAS
             [inference_telemetry.request_latency_ms]. The OAS transport
             layer ([complete_common.patch_telemetry] non-streaming,
             [complete_stream] streaming) synthesizes it whenever a response
             is produced. Both [inference_telemetry] and the field itself are
             [option] (the transport layer may not synthesize a latency for
             every code path), so [Option.bind] flattens the two layers
             rather than nesting option-of-option; on the error path the
             dashboard renders absence for the generation phase rather than a
             fabricated duration. *)
          match turn_result with
          | Ok result ->
              Option.bind result.inference_telemetry (fun t ->
                t.request_latency_ms)
          | Error _ -> None
        in
        let ttfrc_ms : float option =
          (* RFC-0233 §10 — time-to-first-response-chunk (wall-clock, ms),
             sourced from OAS [inference_telemetry.ttfrc_ms]. The streaming
             transport ([complete_stream]) fills it for every provider on the
             first SSE chunk, so it is populated across the streaming keeper
             fleet; non-streaming turns and the error path leave it [None].
             Both [inference_telemetry] and the field are [option], so
             [Option.bind] flattens (same pattern as [request_latency_ms]
             above). The decode (post-first-chunk) duration is NOT derived
             from request_latency_ms - ttfrc_ms (§9.6 fabrication guard). *)
          match turn_result with
          | Ok result ->
              Option.bind result.inference_telemetry (fun t -> t.ttfrc_ms)
          | Error _ -> None
        in
        (* RFC-0233 §2.3 — views derive, no view-side repair: ground the
           inspector's [model] and [finish_reason] in the same refs the
           execution receipt already records this turn. [model] is the
           RFC-0132 boundary-redacted runtime label; [finish_reason] is
           the keeper stop reason serialized through the receipt SSOT
           ([Keeper_execution_receipt.stop_reason_to_string]). Both are
           [None] on the error path (receipt refs unset), never a
           fabricated value. *)
        (* RFC-0233 §8 — ground ctx-window/cost in real runtime facts so the
           dashboard stops fabricating 200K / Claude $3·$15. [context_window]
           is the keeper-resolved effective budget ([max_context]); pricing
           comes from the runtime binding retained in the Runtime singleton
           ([Runtime.pricing_of_runtime_id] projects binding.price_input/output
           — both option, None when the operator left runtime.toml unset, in
           which case the dashboard renders absence rather than a default). *)
        let (price_input_per_million, price_output_per_million) =
          Runtime.pricing_of_runtime_id runtime_id_string
        in
        Keeper_turn_record_writer.write
          ~config
          ~keeper_name:meta.name
          ~trace_id
          ~absolute_turn:manifest_keeper_turn_id
          ~runtime_profile:runtime_id_string
          ~model:!receipt_model_used_ref
          ~finish_reason:
            (Option.map
               Keeper_execution_receipt.stop_reason_to_string
               !receipt_stop_reason_ref)
          ~context_window:(Some max_context)
          ~price_input_per_million
          ~price_output_per_million
          ~request_latency_ms
          ~ttfrc_ms
          ~sampling:
            { temperature = Some temperature
            ; top_p = Runtime.top_p_of_runtime_id runtime_id_string
            ; max_tokens =
                (match pre_dispatch_max_tokens_error with
                 | None -> Some max_tokens
                 | Some _ -> None)
            ; thinking_budget = tctx.thinking_budget
            ; enable_thinking = tctx.thinking_enabled
            }
          ~usage
          ~execution_ids
          ~blocks:acc.prompt_blocks
          ();
        (* RFC-0233 §2.3 PR-4: project the same record onto the ambient
           turn span. Both turn drivers (unified "invoke_agent <keeper>"
           and direct "keeper_turn") keep their span open across this
           tail on the same fiber, so one add_attrs covers both. The
           OTel value type has no array — blocks serialize through the
           Turn_record codec (single encoding SSOT), execution ids join
           with commas. *)
        Otel_spans.add_attrs
          ~attrs:
            [ ( Otel_genai.Attr_key.masc_turn_blocks
              , `String
                  (Yojson.Safe.to_string
                     (`List
                        (List.map Turn_record.prompt_block_to_json
                           acc.prompt_blocks))) )
            ; ( Otel_genai.Attr_key.masc_turn_profile
              , `String runtime_id_string )
            ; ( Otel_genai.Attr_key.masc_turn_execution_ids
              , `String
                  (String.concat ","
                     (List.map Ids.Execution_id.to_string execution_ids)) )
            ]
          ());
       receipt_result)
with
| Eio.Cancel.Cancelled _ as ce ->
  turn_cancelled := Some ce;
  raise ce
