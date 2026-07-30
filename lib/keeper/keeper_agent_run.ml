(** Keeper_agent_run — Run a single keeper turn via OAS Agent.run().

    This module is intentionally a compatibility facade: public types and
    entrypoints stay here while prompt metrics, result/error helpers, and
    tool-surface policy live in focused implementation modules. *)

include Keeper_agent_prompt_metrics
include Keeper_agent_tool_surface
include Keeper_agent_result
include Keeper_agent_error
module Contract_helpers = Keeper_agent_run_contract_helpers
module Turn_helpers = Keeper_agent_run_turn_helpers

let progress_keeper_tool_names_for_contract =
  Contract_helpers.progress_keeper_tool_names_for_contract
;;

let observation_timestamp_ms () =
  (* NDT-OK: wall-clock timestamp for IDE observation telemetry only; keeper
     control flow does not branch on this value. *)
  Int64.of_float (Unix.gettimeofday () *. 1000.0)
;;

let normalize_response_text_for_finalization
      ~runtime_id
      ~initial_messages:_
      ~(run_result : Runtime_agent.run_result)
      ~text
      ~tool_names
      ()
  =
  match run_result.stop_reason with
  | Runtime_agent.Awaiting_external_effect _
  | Runtime_agent.Yielded_to_chat_waiting _
  | Runtime_agent.Yielded_to_durable_stimulus _
  | Runtime_agent.Yielded_after_repeated_tool_call _
  | Runtime_agent.Completed
  | Runtime_agent.InputRequired _ ->
  if
    Keeper_agent_run_response_text.stop_reason_suppresses_visible_response
      run_result.stop_reason
  then Ok ""
  else
    match Keeper_tool_response.normalize_response_text ~text ~tool_names () with
  | Ok response_text -> Ok response_text
  | Error _ ->
    (* Finalization exposes the typed accept-rejected response itself. Tool
       execution history stays in the OAS checkpoint; it is not projected into
       a read/mutating behavioral classification. *)
    Error
      (Keeper_turn_driver_try_provider.accept_rejected_error
         ~runtime_id
         ~response:run_result.response)
;;

(* OAS raw-trace sink for keeper turns: parsed Run_started / Assistant_block /
   Tool_execution / Run_finished records written to a fresh per-turn JSONL
   under [Keeper_types_support.keeper_raw_trace_dir]. Passing the sink into
   [Keeper_turn_driver.run_named] is what populates
   [run_result.trace_ref]/[run_validation] for unified observation consumers.

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

(* What the queue held when the turn decided to yield. The decision itself is
   [pending <> empty], so without this the record says a yield happened and
   nothing about what it yielded to. *)
type durable_stimulus_summary =
  { pending_count : int
  ; head : Keeper_event_queue.stimulus option
  ; head_age_sec : float
  ; kinds : Keeper_event_queue.stimulus_payload list
  }

type autonomous_yield_reason =
  | Chat_waiting
  | Durable_stimulus_waiting of durable_stimulus_summary

type autonomous_yield_request =
  { reason : autonomous_yield_reason }

let durable_stimulus_summary ~now (pending : Keeper_event_queue.t) =
  let stimuli = Keeper_event_queue.to_list pending in
  let kinds =
    List.map (fun (s : Keeper_event_queue.stimulus) -> s.payload) stimuli
  in
  match stimuli with
  | [] -> { pending_count = 0; head = None; head_age_sec = 0.; kinds = [] }
  | head :: _ ->
    { pending_count = List.length stimuli
    ; head = Some head
    ; (* A stimulus stamped by a different clock can sit ahead of [now]. A
         negative age reads as a stimulus from the future rather than as the
         clock skew it is. *)
      head_age_sec = Float.max 0. (now -. head.arrived_at)
    ; kinds
    }
;;

(* Rendering happens here, at the boundary where the value leaves the type
   system for a log line. The summary itself holds the typed payloads. *)
let durable_stimulus_summary_to_string summary =
  let label (payload : Keeper_event_queue.stimulus_payload) =
    Keeper_event_queue.payload_kind_label payload
  in
  Printf.sprintf
    "pending=%d head=%s head_age_sec=%.1f kinds=[%s]"
    summary.pending_count
    (match summary.head with
     | None -> "none"
     | Some head -> label head.payload)
    summary.head_age_sec
    (summary.kinds
     |> List.map label
     |> List.sort_uniq String.compare
     |> String.concat ",")
;;

let runtime_yield_reason request =
  match request.reason with
  | Chat_waiting -> Runtime_agent.Chat_waiting
  | Durable_stimulus_waiting _ ->
    Runtime_agent.Durable_stimulus_waiting
;;

let repeated_tool_call_yield_threshold = 3

let same_present_fingerprint left right =
  match left, right with
  | Some left, Some right -> String.equal left right
  | None, None
  | Some _, None
  | None, Some _ ->
    false
;;

let same_exact_tool_call
      (left : Keeper_agent_result.tool_call_detail)
      (right : Keeper_agent_result.tool_call_detail)
  =
  String.equal left.tool_name right.tool_name
  && same_present_fingerprint left.input_fingerprint right.input_fingerprint
  && same_present_fingerprint left.output_fingerprint right.output_fingerprint
;;

let repeated_exact_tool_call ~threshold tool_calls =
  match tool_calls with
  | [] -> None
  | latest :: previous ->
    let rec count_same count = function
      | call :: rest when same_exact_tool_call latest call ->
        count_same (count + 1) rest
      | _ -> count
    in
    let repeated_count = count_same 1 previous in
    if threshold > 1 && repeated_count >= threshold
    then Some (latest.tool_name, repeated_count)
    else None
;;

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

let provider_transcript_admission messages =
  match Keeper_compaction_unit.validate_provider_transcript messages with
  | Ok () -> Ok ()
  | Error transcript_error ->
    let reason, tool_use_ids =
      match transcript_error with
      | Keeper_compaction_unit.Invalid_transcript_structure _ ->
        Keeper_internal_error.Structurally_invalid, []
      | Keeper_compaction_unit.Unresolved_tool_results { tool_use_ids } ->
        Keeper_internal_error.Unresolved_tool_results, tool_use_ids
    in
    Error
      (Keeper_internal_error.sdk_error_of_masc_internal_error
         (Keeper_internal_error.Incomplete_tool_transcript
            { reason
            ; detail =
                Keeper_compaction_unit.show_provider_transcript_error
                  transcript_error
            ; tool_use_ids
            }))
;;

let dispatch_after_provider_transcript_admission ~messages ~dispatch =
  match provider_transcript_admission messages with
  | Error _ as error -> error
  | Ok () -> dispatch ()
;;

let terminal_effect_boundary_decision = function
  | Keeper_tools_oas.Terminal_effect_open -> Ok Runtime_agent.Continue
  | Keeper_tools_oas.Deferred_tool_result ->
    Ok (Runtime_agent.Yield Runtime_agent.Durable_stimulus_waiting)
  | Keeper_tools_oas.External_effect_deferred ->
    Ok (Runtime_agent.Yield Runtime_agent.External_effect_deferred)
  | Keeper_tools_oas.Terminal_effect_completed ->
    Ok (Runtime_agent.Yield Runtime_agent.Terminal_tool_completed)
  | Keeper_tools_oas.Terminal_effect_failed
      { failure_class; effect_disposition; diagnostic } ->
    Error
      (Keeper_internal_error.sdk_error_of_masc_internal_error
         (Keeper_internal_error.Terminal_effect_failed
            { failure_class; effect_disposition; diagnostic }))
;;

module For_testing = struct
  let sse_event_progress_kind = Turn_helpers.sse_event_progress_kind
  let sse_event_watchdog_progress_kind =
    Turn_helpers.sse_event_watchdog_progress_kind
  let registry_progress_on_event = Turn_helpers.registry_progress_on_event
  let progress_keeper_tool_names_for_contract =
    Contract_helpers.progress_keeper_tool_names_for_contract
  let normalize_response_text_for_finalization =
    normalize_response_text_for_finalization
  let keeper_raw_trace_sink = keeper_raw_trace_sink
  let raw_trace_for_dispatch = raw_trace_for_dispatch
  let runtime_yield_reason = runtime_yield_reason
  let repeated_exact_tool_call = repeated_exact_tool_call
  let provider_transcript_admission = provider_transcript_admission
  let dispatch_after_provider_transcript_admission =
    dispatch_after_provider_transcript_admission
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
    @param temperature Subsystem temperature fallback; a selected runtime model
           declaration takes precedence. When omitted,
           [Keeper_config.keeper_unified_temperature] is the fallback.
    @param is_retry When [true], replays the current user message into the
           working context without persisting it again, so transient retry
           attempts do not duplicate the user entry in session history *)
let run_turn
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(publication_recovery :
          Keeper_publication_recovery_availability.turn_context)
      ~(profile_defaults : Keeper_types_profile.keeper_profile_defaults)
      ~(turn_ctx_cell : Keeper_tool_call_log.turn_ctx_cell)
      ~(base_dir : string)
      ~(max_context : int)
      ~(build_turn_prompt :
         base_system_prompt:string -> messages:Agent_sdk.Types.message list -> turn_prompt)
      ~(user_message : string)
      ?user_blocks
      ~(runtime_id : string)
      ?world_observation
      ~(generation : int)
      ?(history_user_source = "direct_user")
      ?(user_turn_record = Keeper_run_prompt.Record_user_turn)
      ?(history_assistant_source = "direct_assistant")
      ?temperature
      ?on_event
      ?(trajectory_acc : Trajectory.accumulator option)
      ?(degraded_retry_applied = false)
      ?degraded_retry_runtime
      ?fallback_reason
      ?(runtime_rotation_attempts = [])
      ?deferred_runtime_lane
      ?on_runtime_retry_deferred
      ?on_deferred_runtime_consumed
      ?(is_retry = false)
      ?shared_context
      ?event_bus
      ?trace_link
      ?continuation_channel
      ?continuation_delivery_channel
      ?hitl_resolution
      ?autonomous_yield_requested
      ?on_checkpoint_stage
      ()
  : (run_result, Agent_sdk.Error.sdk_error) result
  =
  (* Section 1: Setup — sanitize input, build context, compose prompt. *)
  let deferred_runtime_lane_ref = ref None in
  let record_runtime_retry_deferred hint =
    deferred_runtime_lane_ref := Some hint;
    Option.iter (fun callback -> callback hint) on_runtime_retry_deferred
  in
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
  Keeper_registry.set_turn_switch ~base_path:config.base_path meta.name (Some turn_sw);
  Eio.Switch.on_release turn_sw (fun () ->
    Keeper_registry.clear_turn_switch ~base_path:config.base_path meta.name);
  Eio_context.with_turn_switch turn_sw
  @@ fun () ->
  let runtime_id_string = runtime_id in
  (* Steps 0–4: inference params, session dir, checkpoint, base prompt,
     working context, checkpoint hygiene — all in Keeper_run_context. *)
  let ctx =
    Keeper_run_context.prepare_run_context
      ~config
      ~meta
      ~profile_defaults
      ~base_dir
      ~runtime_id
      ?temperature
      ?shared_context
      ~generation
      ()
  in
  let meta = ctx.meta in
  let temperature = ctx.temperature in
  let context_injector = ctx.context_injector in
  let shared_context = ctx.shared_context in
  let session = ctx.session in
  let base_system_prompt = ctx.base_system_prompt in
  let resume_oas_checkpoint = ctx.resume_oas_checkpoint in
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
          [ "loaded_checkpoint_present", `Bool ctx.loaded_checkpoint_present ]))
    Keeper_runtime_manifest.Checkpoint_loaded;
  (* Steps 5-6: turn prompt, memory/temporal context, prompt metrics,
     and user message append — Keeper_run_prompt. *)
  let prompt_user_turn_record =
    match hitl_resolution with
    | Some _ -> Keeper_run_prompt.Skip_uninformative_wake
    | None -> user_turn_record
  in
  let prompt_ctx =
    Keeper_run_prompt.build_turn_context
      ~ctx
      ~build_turn_prompt
      ~user_message
      ~config
      ~meta
      ~history_user_source
      ~user_turn_record:prompt_user_turn_record
      ~is_retry
      ~start_turn_count
  in
  let turn_system_prompt = prompt_ctx.Keeper_run_prompt.turn_system_prompt in
  let dynamic_context = prompt_ctx.Keeper_run_prompt.dynamic_context in
  let memory_context = prompt_ctx.Keeper_run_prompt.memory_context in
  let temporal_context = prompt_ctx.Keeper_run_prompt.temporal_context in
  let history_messages = prompt_ctx.Keeper_run_prompt.history_messages in
  let resume_oas_checkpoint =
    Option.map
      (fun (checkpoint : Agent_sdk.Checkpoint.t) ->
        { checkpoint with messages = history_messages })
      resume_oas_checkpoint
  in
  let ctx_work = prompt_ctx.Keeper_run_prompt.ctx_work in
  (* 7. Set up agent — delegated to Keeper_run_tools *)
  let setup =
    Keeper_run_tools.prepare_agent_setup
      ~config
      ~meta
      ~publication_recovery
      ?continuation_channel
      ?hitl_resolution
      ~turn_ctx_cell
      ~ctx_work
      ~session
      ~base_system_prompt
      ~turn_system_prompt
      ~user_message
      ~dynamic_context
      ~history_messages
      ~shared_context
      ~context_injector
      ~start_turn_count
      ~generation
      ~keeper_turn_id:manifest_keeper_turn_id
      ~runtime_id
      ~is_retry
      ~config_root
      ~runtime_config_path
      ~trajectory_acc
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
    let user_message = s.Keeper_run_tools.user_message in
    let user_blocks =
      match user_blocks, s.Keeper_run_tools.gate_replay_evidence with
      | Some blocks, Some evidence ->
        Some (Keeper_gate_replay.append_model_evidence_block evidence blocks)
      | (Some _ as blocks), None -> blocks
      | None, _ -> None
    in
    let ctx_work =
      match hitl_resolution with
      | None -> ctx_work
      | Some _ ->
        let user_message = Agent_sdk.Types.user_msg user_message in
        Keeper_context_runtime.append ctx_work user_message
    in
    let prompt_metrics =
      Keeper_agent_prompt_metrics.build_prompt_metrics
        ~system_prompt:turn_system_prompt
        ~dynamic_context
        ~user_message
    in
    let history_messages_digest =
      digest_message_texts_as_joined history_messages
    in
    let context_digest =
      digest_text
        (base_system_prompt ^ turn_system_prompt ^ dynamic_context
         ^ memory_context ^ temporal_context ^ user_message
         ^ history_messages_digest)
    in
    append_manifest
      ~site:"context_injected"
      ~keeper_turn_id:manifest_keeper_turn_id
      ?checkpoint_path:
        (if ctx.loaded_checkpoint_present then Some checkpoint_path else None)
      ~decision:
        (Keeper_runtime_manifest.with_payload_role
           ~payload_role:Model_input
           (`Assoc
              [ ( "base_system_prompt_digest"
                , `String (digest_text base_system_prompt) )
              ; ( "turn_system_prompt_digest"
                , `String (digest_text turn_system_prompt) )
              ; ( "dynamic_context_digest"
                , `String (digest_text dynamic_context) )
              ; "memory_context_digest", `String (digest_text memory_context)
              ; ( "temporal_context_digest"
                , `String (digest_text temporal_context) )
              ; "user_message_digest", `String (digest_text user_message)
              ; "history_message_count", `Int (List.length history_messages)
              ; "history_messages_digest", `String history_messages_digest
              ; "context_window", `Int max_context
              ; "context_digest", `String context_digest
              ]))
      Keeper_runtime_manifest.Context_injected;
    let cleanup_agent_setup () =
      Turn_helpers.cleanup_agent_setup ~keeper_name:meta.name s
    in
    Turn_helpers.run_with_setup_cleanup ~cleanup:cleanup_agent_setup
    @@ fun () ->
    let tools = s.Keeper_run_tools.tools in
    let hooks = s.Keeper_run_tools.hooks in
    let acc = s.Keeper_run_tools.acc in
    let agent_ref : Agent_sdk.Agent.t option ref = ref None in
    let final_oas_turn_ordinal_ref =
      s.Keeper_run_tools.final_oas_turn_ordinal_ref
    in
    let receipt_turn_count_ref = s.Keeper_run_tools.receipt_turn_count_ref in
    let receipt_model_used_ref = s.Keeper_run_tools.receipt_model_used_ref in
    let receipt_stop_reason_ref = s.Keeper_run_tools.receipt_stop_reason_ref in
    let receipt_runtime_observation_ref =
      s.Keeper_run_tools.receipt_runtime_observation_ref
    in
    let receipt_response_text_present_ref =
      s.Keeper_run_tools.receipt_response_text_present_ref
    in
    let request_evidence_ref = ref None in
    let current_request_input_messages_ref = ref None in
    let source_model_input_projection =
      s.Keeper_run_tools.model_input_projection
    in
    let model_input_projection messages =
      match source_model_input_projection messages with
      | Error _ as error -> error
      | Ok projected_messages as result ->
        let prompt_context_present =
          Option.is_some acc.Keeper_run_tools.extra_system_context_size
        in
        (match
           Keeper_agent_prompt_metrics.provider_content_messages
             ~prompt_context_present
             ~projection_input:messages
             ~projected_messages
         with
         | Some provider_content ->
           current_request_input_messages_ref := Some provider_content
         | None ->
           current_request_input_messages_ref := None;
           Log.Keeper.warn
             "turn input composition unavailable: keeper=%s trace=%s \
              reason=model_input_projection_rewrote_prefix"
             meta.name trace_id);
        result
    in
    (* 8. Run Agent *)
    let record_turn_progress, yield_on_tool, on_yield, on_resume, on_event =
      Turn_helpers.turn_progress_callbacks
        ~config
        ~keeper_name:meta.name
        ~downstream:on_event
        ~turn_id:manifest_keeper_turn_id
    in
    ignore (Keeper_alerting_path.ensure_sandbox_bundle ~config ~meta);
    let _keeper_sandbox_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
    let keeper_visible_sandbox_root =
      Keeper_sandbox.keeper_visible_root_abs_of_meta ~config meta
    in
    (* Tool/path confinement stays owned by MASC dispatch. Each filesystem and
       shell operation resolves its concrete target through
       [Keeper_alerting_path] and [Keeper_sandbox_containment]; OAS receives no
       ambient path capability. *)
    (
       (* OAS [stream_idle_timeout_s] bounds inter-line idle on HTTP streams
          only when the operator explicitly configures it. The deadline resets
          after each successful line, so this is gap detection, not a total run
          cap. [None] is carried unchanged: neither MASC nor OAS may infer a
          provider/model default. *)
       let stream_idle_timeout_s =
         Keeper_runtime_resolved.stream_idle_timeout_sec ()
       in
       Keeper_agent_run_phase0_telemetry.record
         ~meta
         ~turn_system_prompt
         ~tools
         ~history_messages
         ?user_blocks
         ~user_message
         ~start_turn_count
         ~max_context
         ();
       (* Section 3: Dispatch — call Keeper_turn_driver.run_named / Agent.run. *)
       let turn_result =
         let cooperative_yield_probe =
           Some
             (fun (_ : Agent_sdk.Agent.Advanced.tool_boundary) ->
                try
                  (* OAS invokes this probe after tool results and the
                     checkpoint have persisted. A descriptor-typed terminal
                     effect therefore either completes the turn or fails it;
                     neither state can re-enter the provider loop. *)
                  (match
                     terminal_effect_boundary_decision (s.terminal_effect_state ())
                   with
                   | Error _ as error -> error
                   | Ok (Runtime_agent.Yield _ as decision) -> Ok decision
                   | Ok Runtime_agent.Continue ->
                     let repeated_tool_call_decision () =
                           (match
                              repeated_exact_tool_call
                                ~threshold:repeated_tool_call_yield_threshold
                                s.acc.tool_calls
                            with
                            | None -> Ok Runtime_agent.Continue
                            | Some (tool_name, repeated_count) ->
                              Log.Keeper.warn
                                ~keeper_name:meta.name
                                "yielding repeated exact tool loop tool=%s \
                                 count=%d"
                                tool_name
                                repeated_count;
                              Ok
                                (Runtime_agent.Yield
                                   (Runtime_agent.Repeated_tool_call
                                      { tool_name; repeated_count })))
                     in
                     (match autonomous_yield_requested with
                      | None -> repeated_tool_call_decision ()
                      | Some requested ->
                        (match requested () with
                         | Ok (Some request) ->
                           Ok (Runtime_agent.Yield (runtime_yield_reason request))
                         | Ok None -> repeated_tool_call_decision ()
                         | Error detail ->
                           Error
                             (Agent_sdk.Error.Internal
                                ("keeper cooperative-yield snapshot failed: "
                                 ^ detail)))))
                with
                | Eio.Cancel.Cancelled _ as exn -> raise exn
                | exn ->
                  Error
                    (Agent_sdk.Error.Internal
                       (Printf.sprintf
                          "keeper cooperative-yield probe failed: %s"
                          (Printexc.to_string exn))))
         in
         let checkpoint_sidecar =
                ctx_work.checkpoint.Agent_sdk.Checkpoint.working_context
         in
         let checkpoint_sink (snapshot : Agent_sdk.Agent.checkpoint_snapshot) =
                Option.iter (fun observe -> observe snapshot.stage) on_checkpoint_stage;
                (* OAS's per-turn pipeline builds checkpoints with an empty
                   session_id (the OAS agent carries no session field), so the
                   sink must stamp the keeper's own session identity before
                   persisting. [meta.runtime.trace_id] is a validated,
                   non-empty [Trace_id.t]; without this restamp the checkpoint
                   transaction rejects an invalid persistence identity. *)
                let checkpoint =
                  { snapshot.checkpoint with
                    session_id =
                      Keeper_id.Trace_id.to_string meta.runtime.trace_id
                  ; working_context =
                      (match checkpoint_sidecar with
                       | Some _ as sidecar -> sidecar
                       | None -> snapshot.checkpoint.working_context)
                  }
                in
                match
                  Keeper_checkpoint_store.save_oas_classified
                    ~session_dir:session.session_dir
                    checkpoint
                with
                | Ok _ -> Ok ()
                | Error _ as error -> error
         in
         let call_run_named ?raw_trace ~initial_messages () =
                (* Keeper does not impose a cumulative turn, time, token, or cost
                   budget. Explicit cancellation and provider/tool progress
                   boundaries settle the lane, while usage remains observational. *)
                dispatch_after_provider_transcript_admission
                  ~messages:initial_messages
                  ~dispatch:(fun () ->
                    Keeper_turn_driver.run_named
                      ~runtime_id:runtime_id_string
                      ~base_path:config.base_path
                      ~keeper_name:meta.name
                      ~goal:user_message
                      ?goal_blocks:user_blocks
                      ~session_id:
                        (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                      ?raw_trace
                      ~system_prompt:turn_system_prompt
                      ~tools
                      ~checkpoint_sink
                      ~initial_messages
                      ~model_input_projection
                      ~hooks
                      ~runtime_manifest_context
                      ~runtime_manifest_append:
                        (fun manifest ->
                           Keeper_runtime_manifest.append_best_effort
                             ~site:"runtime_runtime"
                             config
                             manifest)
                      ?deferred_runtime_lane
                      ~on_runtime_retry_deferred:record_runtime_retry_deferred
                      ?on_deferred_runtime_consumed
                      ?stream_idle_timeout_s
                      ?body_timeout_s:
                        (Keeper_runtime_resolved.body_timeout_override_sec ())
                      ~temperature
                      ~accept:
                        Keeper_tool_response.response_has_text_or_tool_progress
                      ?on_event
                      ?on_yield
                      ?on_resume
                      ~agent_ref
                      ?checkpoint_sidecar
                      ~cache_system_prompt:true
                      ~yield_on_tool
                      ~context_injector
                      ~context:shared_context
                      ~enable_thinking:(Keeper_config.keeper_enable_thinking ())
                      ?cooperative_yield_probe
                      ?oas_checkpoint:resume_oas_checkpoint
                      ?event_bus
                      ?trace_link
                      ~on_runtime_observation:
                        (fun observation ->
                           receipt_runtime_observation_ref := Some observation)
                      ~on_request_wire_observation:
                        (fun
                          ~runtime_id
                          ~max_request_body_bytes
                          ~body_bytes
                        ->
                           Keeper_request_wire_observation.record
                             ~keeper_name:meta.name
                             ~runtime_id
                             ~max_request_body_bytes
                             ~body_bytes;
                           request_evidence_ref :=
                             Some
                               ( { Turn_record.runtime_profile = runtime_id
                                 ; body_bytes
                                 }
                               , !current_request_input_messages_ref ))
                      ())
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
                   match !request_evidence_ref with
                   | Some (_, Some input_messages) ->
                     Keeper_agent_prompt_metrics.build_ctx_composition_metrics
                       ~prompt_blocks:acc.prompt_blocks
                       ~tools
                       ~input_messages
                       ~actual_input_tokens:(Some usage.input_tokens)
                   | Some (_, None) | None ->
                     { Keeper_agent_prompt_metrics.actual_input_tokens =
                         (if usage.input_tokens > 0
                          then Some usage.input_tokens
                          else None)
                     ; attributed_bytes = 0
                     ; segments = []
                     }
                 in
                 let completion_observation ()
                     : Keeper_execution_receipt.completion_contract_result =
                   Contract_helpers.observed_completion_evidence
                     ~actual_keeper_tool_names:progress_keeper_tool_names
                     ~stop_reason:result.stop_reason
                     ~response_text_present:(String.trim text <> "")
                 in
                 let completion_observation = completion_observation () in
                 acc.receipt_completion_contract_result <- completion_observation;
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
                        (match !final_oas_turn_ordinal_ref with
                         | None ->
                           Error
                             (Agent_sdk.Error.Internal
                                "successful Agent.run returned without an \
                                 AfterTurn ordinal")
                         | Some final_oas_turn_ordinal ->
                           Keeper_agent_run_finalize_response.finalize
                             ~config ~meta ~generation ~manifest_keeper_turn_id
                             ~session ~append_manifest ~model
                             ~acc
                             ~actual_keeper_tool_names
                             ~user_turn_record
                             ~result ~final_oas_turn_ordinal
                             ~checkpoint_persistence_error
                             ~post_turn_t0 ~runtime_id_string
                             ~history_messages
                             ~prompt_metrics ~ctx_composition ~usage
                             ~receipt_response_text_present_ref
                             ~history_assistant_source
                             ~raw_response_text:response_text
                             ?continuation_delivery_channel
                             ~capture_replay_response:
                               (fun ~response_text ->
                                 (* Phase O observability: capture the exact
                                    assistant text persisted for next-turn replay,
                                    after response finalization has applied
                                    suppression and internal-markup stripping. The
                                    capture is best-effort and gated by
                                    MASC_KEEPER_WIRE_CAPTURE. *)
                                 Keeper_wire_capture.capture_response
                                   ~base_path:config.base_path
                                   ~masc_root:(Workspace.masc_root_dir config)
                                   ~keeper_name:meta.name
                                   ~turn_id:manifest_keeper_turn_id
                                   ~sdk_turn:result.turns
                                   ~trace_id:meta.runtime.trace_id
                                   ~response_text
                                   ())
                             ())))
               in
       let deferred_retry =
         Option.map
           (fun (hint : Keeper_turn_driver.deferred_runtime_lane) ->
              let reason =
                match
                  Keeper_error_classify.recoverable_runtime_failure_reason
                    hint.failure
                with
                | Some reason -> reason
                | None -> Keeper_error_classify.Deferred_runtime_lane
              in
              hint.next_runtime_id, reason)
           !deferred_runtime_lane_ref
       in
       let receipt_degraded_retry_runtime =
         match deferred_retry with
         | Some (runtime_id, _) -> Some runtime_id
         | None -> degraded_retry_runtime
       in
       let receipt_fallback_reason =
         match deferred_retry with
         | Some (_, reason) -> Some reason
         | None -> fallback_reason
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
           ~degraded_retry_applied
           ~degraded_retry_runtime:receipt_degraded_retry_runtime
           ~fallback_reason:receipt_fallback_reason
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
            (* Cache counts travel with the turn rather than being dropped: a large
               input_tokens on a cache-heavy turn and one on a genuinely large prompt
               read identically without them, and the ctx-fill denominator below is the
               compaction ceiling, so the difference is what an operator acts on. *)
            { input_tokens = Some result.usage.input_tokens
            ; output_tokens = Some result.usage.output_tokens
            ; cache_creation_input_tokens =
                Some result.usage.cache_creation_input_tokens
            ; cache_read_input_tokens = Some result.usage.cache_read_input_tokens
            }
          | Ok _ | Error _ ->
            { input_tokens = None
            ; output_tokens = None
            ; cache_creation_input_tokens = None
            ; cache_read_input_tokens = None
            }
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
        let input_components =
          let segments =
            match turn_result, !request_evidence_ref with
            | Ok result, _ ->
              result.Keeper_agent_result.ctx_composition.segments
            | Error _, Some (_, Some input_messages) ->
              (Keeper_agent_prompt_metrics.build_ctx_composition_metrics
                 ~prompt_blocks:acc.prompt_blocks
                 ~tools
                 ~input_messages
                 ~actual_input_tokens:None)
                .segments
            | Error _, (Some (_, None) | None) -> []
          in
          List.map
            (fun
              (component,
               (segment :
                 Keeper_agent_prompt_metrics.prompt_segment_metrics)) ->
               { Turn_record.component = component; bytes = segment.bytes })
            segments
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
          ~request_wire_observation:(Option.map fst !request_evidence_ref)
          ~sampling:
            { temperature = Some temperature
            ; top_p = Runtime.top_p_of_runtime_id runtime_id_string
            ; max_tokens = None
            ; thinking_budget = tctx.thinking_budget
            ; enable_thinking = tctx.thinking_enabled
            }
          ~usage
          ~execution_ids
          ~blocks:acc.prompt_blocks
          ~input_components
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
| Eio.Cancel.Cancelled Keeper_registry.Operator_interrupt as ce ->
  turn_cancelled := Some ce;
  Keeper_registry.set_failure_reason
    ~base_path:config.base_path meta.name (Some Keeper_registry.Operator_interrupt);
  raise ce
| Eio.Cancel.Cancelled _ as ce ->
  turn_cancelled := Some ce;
  raise ce
