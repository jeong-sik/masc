(** Keeper_agent_run — Run a single keeper turn via OAS Agent.run().

    This module is intentionally a compatibility facade: public types and
    entrypoints stay here while prompt metrics, result/error helpers, and
    tool-surface policy live in focused implementation modules. *)

include Keeper_agent_prompt_metrics
include Keeper_agent_tool_surface
include Keeper_agent_result
include Keeper_agent_error
include Keeper_agent_checkpoint_hygiene

(* Post-turn telemetry logging — extracted to Keeper_turn_telemetry (#5732) *)

let per_provider_timeout_for_turn
      ~(meta : Keeper_types.keeper_meta)
      ?oas_timeout_s
      ~(timeout_s : float)
      ()
  =
  match oas_timeout_s with
  | Some _ as explicit_timeout -> explicit_timeout
  | None ->
    (match meta.per_provider_timeout_s with
     | Some _ as configured -> configured
     | None -> Some timeout_s)
;;

(** Run a single keeper turn via OAS Agent.run().

    Loads checkpoint, creates working context with the base keeper system
    prompt, then calls [build_turn_prompt] with the base prompt and message
    history so the caller can layer skill routing, continuity context,
    policy guards, and turn-specific instructions on top.

    After the callback returns the final system prompt, appends the user
    message, builds OAS tools + hooks, and delegates to
    [Keeper_turn_driver.run_named] which internally calls Agent.run().

    @param config Coord configuration
    @param meta Keeper metadata
    @param base_dir Session base directory for checkpoints
    @param max_context Maximum context window tokens
    @param build_turn_prompt Callback: receives the base keeper system prompt
           and checkpoint message history, returns the final turn system prompt
    @param user_message The user's message to the keeper
    @param cascade_name Runtime cascade profile name for model selection
    @param generation Current generation counter
    @param max_turns Maximum agent turns (default from keeper runtime config)
    @param guardrails Optional OAS guardrails for tool safety gates
    @param temperature MODEL temperature override; when omitted, resolved
           from [Cascade_inference] with a 0.3 fallback
    @param max_tokens Maximum output tokens override; when omitted, resolved
           from [Cascade_inference] with a 8192 fallback
    @param is_retry When [true], replays the current user message into the
           working context without persisting it again, so transient retry
           attempts do not duplicate the user entry in session history *)
let run_turn
      ~(config : Coord.config)
      ~(meta : Keeper_types.keeper_meta)
      ~(base_dir : string)
      ~(max_context : int)
      ~(build_turn_prompt :
         base_system_prompt:string -> messages:Agent_sdk.Types.message list -> turn_prompt)
      ~(user_message : string)
      ~(cascade_name : Keeper_cascade_profile.runtime_name)
      ?world_observation
      ?(turn_affordances = [])
      ?(required_tool_names = [])
      ?provider_filter
      ~(generation : int)
      ?(max_turns : int = Keeper_runtime_resolved.reactive_max_turns_per_call ())
      (* Per-call turn budget. Keeper resumes via checkpoint if exhausted. *)
      ?(max_idle_turns : int = 3)
      ?(history_user_source = "direct_user")
      ?(history_assistant_source = "direct_assistant")
      ?guardrails
      ?temperature
      ?max_tokens
      ?oas_timeout_s
      ?max_cost_usd
      ?on_event
      ?(trajectory_acc : Trajectory.accumulator option)
      ?(tool_overlay : Agent_sdk.Tool_op.t ref option)
      ?priority
      ?(degraded_retry_applied = false)
      ?degraded_retry_cascade
      ?fallback_reason
      ?(cascade_rotation_attempts = [])
      ?(is_retry = false)
      ?shared_context
      ?event_bus
      ()
  : (run_result, Agent_sdk.Error.sdk_error) result
  =
  let user_message = Keeper_run_prompt.sanitize_user_message user_message in
  Masc_runtime_events.emit_turn_start ();
  (* Cancel-safe cleanup (#9747): stdlib [Fun.protect] wraps finally
     exceptions in [Fun.Finally_raised], masking the outer
     [Eio.Cancel.Cancelled] raised by the turn body during fleet-wide
     cancellation. Swallow Cancelled in the finally (the outer one is
     already in flight) and log non-cancel exceptions instead of
     propagating them. Mirrors the pattern used in
     [keeper_unified_turn.ml] (#9747 iter 1). *)
  let safe_emit_turn_end () =
    try Masc_runtime_events.emit_turn_end () with
    | Eio.Cancel.Cancelled _ -> ()
    | e ->
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_dispatch_event_failures
        ~labels:[ "keeper", meta.name; "site", "emit_turn_end" ]
        ();
      Log.Keeper.warn
        "%s: emit_turn_end in finally raised: %s"
        meta.name
        (Printexc.to_string e)
  in
  Eio_guard.protect ~finally:safe_emit_turn_end
  @@ fun () ->
  let cascade_name_string = Keeper_cascade_profile.runtime_name_to_string cascade_name in
  (* Steps 0–4: inference params, session dir, checkpoint, base prompt,
     working context, checkpoint hygiene — all in Keeper_run_context. *)
  let ctx =
    Keeper_run_context.prepare_run_context
      ~config
      ~meta
      ~base_dir
      ~max_context
      ~cascade_name
      ?temperature
      ?max_tokens
      ?shared_context
      ~generation
      ()
  in
  let temperature = ctx.temperature in
  let max_tokens = ctx.max_tokens in
  let context_injector = ctx.context_injector in
  let shared_context = ctx.shared_context in
  let session_dir = ctx.session_dir in
  let session = ctx.session in
  let base_system_prompt = ctx.base_system_prompt in
  let resume_oas_checkpoint = ctx.resume_oas_checkpoint in
  let pre_dispatch_compacted = ctx.pre_dispatch_compacted in
  let pre_dispatch_checkpoint_error = ctx.pre_dispatch_checkpoint_error in
  let start_turn_count = ctx.start_turn_count in
  let receipt_started_at = ctx.receipt_started_at in
  let config_root = ctx.config_root in
  let cascade_config_path = ctx.cascade_config_path in
  let gemini_mcp_disabled = ctx.gemini_mcp_disabled in
  let approval_mode_effective = ctx.approval_mode_effective in
  let approval_mode_derived = ctx.approval_mode_derived in
  let keeper_oas_context = ctx.keeper_oas_context in
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
  (* 7. Set up agent — delegated to Keeper_run_tools *)
  let setup =
    Keeper_run_tools.prepare_agent_setup
      ~config
      ~meta
      ~ctx_work
      ~session
      ~base_system_prompt
      ~turn_system_prompt
      ~user_message
      ~dynamic_context
      ~history_messages
      ~prompt_metrics
      ~shared_context
      ~context_injector
      ~start_turn_count
      ~generation
      ~max_turns
      ~cascade_name
      ~is_retry
      ~turn_affordances
      ~required_tool_names
      ~config_root
      ~cascade_config_path
      ~gemini_mcp_disabled
      ~approval_mode_effective
      ~approval_mode_derived
      ?max_cost_usd
      ~trajectory_acc
      ~tool_overlay
      ()
  in
  match setup with
  | Error e -> Error e
  | Ok s ->
    let cleanup_agent_setup () =
      try s.Keeper_run_tools.cleanup () with
      | Eio.Cancel.Cancelled _ -> ()
      | e ->
        let backtrace = Printexc.get_backtrace () in
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_dispatch_event_failures
          ~labels:[ "keeper", meta.name; "site", "tool_cleanup" ]
          ();
        Log.Keeper.warn
          "%s: keeper tool bundle cleanup raised: %s%s"
          meta.name
          (Printexc.to_string e)
          (if String.equal backtrace "" then "" else "\n" ^ backtrace)
    in
    let run_with_setup_cleanup f =
      match f () with
      | result ->
        cleanup_agent_setup ();
        result
      | exception e ->
        let backtrace = Printexc.get_raw_backtrace () in
        cleanup_agent_setup ();
        Printexc.raise_with_backtrace e backtrace
    in
    run_with_setup_cleanup
    @@ fun () ->
    let tools = s.Keeper_run_tools.tools in
    let hooks = s.Keeper_run_tools.hooks in
    let reducer = s.Keeper_run_tools.reducer in
    let memory = s.Keeper_run_tools.memory in
    let acc = s.Keeper_run_tools.acc in
    let agent_ref : Agent_sdk.Agent.t option ref = ref None in
    let initial_tool_surface = s.Keeper_run_tools.initial_tool_surface in
    let initial_tool_surface_blocker_ref =
      s.Keeper_run_tools.initial_tool_surface_blocker
    in
    let all_tool_names = s.Keeper_run_tools.all_tool_names in
    let tool_usage_before = s.Keeper_run_tools.tool_usage_before in
    let receipt_turn_count_ref = s.Keeper_run_tools.receipt_turn_count_ref in
    let receipt_model_used_ref = s.Keeper_run_tools.receipt_model_used_ref in
    let receipt_stop_reason_ref = s.Keeper_run_tools.receipt_stop_reason_ref in
    let receipt_cascade_observation_ref =
      s.Keeper_run_tools.receipt_cascade_observation_ref
    in
    let receipt_response_text_present_ref =
      s.Keeper_run_tools.receipt_response_text_present_ref
    in
    let reported_tool_names_ref = s.Keeper_run_tools.reported_tool_names_ref in
    let observed_tool_names_ref = s.Keeper_run_tools.observed_tool_names_ref in
    let canonical_tool_names_ref = s.Keeper_run_tools.canonical_tool_names_ref in
    let unexpected_tool_names_ref = s.Keeper_run_tools.unexpected_tool_names_ref in
    let actual_keeper_tool_names_ref = s.Keeper_run_tools.actual_keeper_tool_names_ref in
    let keeper_has_owned_active_task () =
      Option.is_some (owned_active_task_id_for_meta ~config ~meta:acc.meta)
    in
    (* A claim tool mutates [acc.meta.current_task_id] during this run; contract
     gating must judge claim-context tools against ownership at turn entry. *)
    let had_owned_active_task_at_turn_start = keeper_has_owned_active_task () in
    (* 8. Run Agent *)
    let contract =
      if Env_config.Cdal.enabled ()
      then Keeper_cdal_contract.of_keeper_meta meta
      else None
    in
    let yield_on_tool = Env_config.Slot.yield_enabled () in
    let on_yield =
      if yield_on_tool
      then
        Some
          (fun () -> Log.Misc.debug "keeper %s: slot yielded (tool execution)" meta.name)
      else None
    in
    let on_resume =
      if yield_on_tool
      then
        Some
          (fun () -> Log.Misc.debug "keeper %s: slot resumed (next LLM turn)" meta.name)
      else None
    in
    let priority =
      Option.value priority ~default:Llm_provider.Request_priority.Proactive
    in
    let admission_wait_timeout_sec =
      if
        Llm_provider.Request_priority.resolve priority
        = Llm_provider.Request_priority.Proactive
      then Some (Keeper_runtime_resolved.admission_wait_timeout_sec ())
      else None
    in
    ignore (Keeper_alerting_path.ensure_sandbox_bundle ~config ~meta);
    let keeper_sandbox_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
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
       let require_tool_choice_support =
         initial_tool_surface.tool_requirement = Required
       in
       let actionable_observation_requires_tool_support =
         match world_observation with
         | None -> false
         | Some observation ->
           observation
           |> Keeper_contract_classifier.of_keeper_world_observation
           |> Keeper_contract_classifier.requires_tool_support_for_allowed_tools
                ~allowed_tool_names:all_tool_names
       in
       let require_tool_support =
         tools <> []
         && (initial_tool_surface.tool_requirement = Required
             || actionable_observation_requires_tool_support)
       in
       let timeout_s =
         match oas_timeout_s with
         | Some value -> value
         | None ->
           Keeper_runtime_resolved.oas_timeout_for_estimated_input_tokens
             ~estimated_input_tokens
       in
       let per_provider_timeout_s =
         per_provider_timeout_for_turn ~meta ?oas_timeout_s ~timeout_s ()
       in
       (* OAS [stream_idle_timeout_s] bounds inter-line idle on HTTP streams
       (Anthropic/OpenAI/Gemini/GLM/Ollama). The deadline resets after each
       successful line, so this is gap detection, not total run cap.

       CLI subprocess transports use a separate envelope:
       [cli_subprocess_idle_sec], wired into [cli_transport_overrides]
       below and forwarded to [Cli_common_subprocess.run_stream_lines]
       via [stdout_idle_timeout_s] (Kimi CLI today; Claude Code / Gemini
       CLI / Codex CLI need an OAS upstream change to expose the same
       parameter in their transport configs).

       Default 120 s catches real network/stream hangs while preserving
       legitimate reasoning pauses + provider keepalives. If the total
       OAS timeout is shorter, the idle gap is clamped to that total cap
       so the nested timeout envelope is explicit. *)
       let stream_idle_timeout_s =
         Some
           (Keeper_runtime_resolved.stream_idle_timeout_for_total_timeout
              ~total_timeout_s:timeout_s)
       in
       (* Observability for issue #10049: providers that declare runtime MCP
       HTTP header support need claude_mcp_config to reach the masc-mcp
       HTTP MCP endpoint; otherwise the MCP tool catalog is invisible to
       the subprocess and the model will correctly report that no shell
       tools are bound. *)
       if keeper_oas_context.claude_mcp_config = None
       then (
         let uses_cli_missing_sync =
           List.exists
             Provider_adapter.supports_runtime_mcp_http_headers_for_model_label
             meta.models
         in
         if uses_cli_missing_sync
         then
           Log.Keeper.warn
             "keeper %s (cascade=%s): cli-backed providers selected but \
              claude_mcp_config is None; MCP tool catalog will not be visible to the \
              subprocess (see issue #10049 for fix plan)"
             meta.name
             cascade_name_string);
       let cli_transport_overrides =
         let claude_mcp_config =
           match keeper_oas_context.claude_mcp_config with
           | Some _ as cfg -> cfg
           | None ->
             (* #10049 Option C: auto-construct from the keeper bearer
               token + server host/port when env is unset. Gated
               behind MASC_AUTO_CONSTRUCT_CLAUDE_MCP (default true). The
               existing explicit-env path still wins, and operators can opt
               out by setting the flag false. Returns [None] when the flag
               is off or the token file is missing — the Log.Keeper.warn
               above (iter 10052) still fires for visibility. *)
             Keeper_cli_mcp_config.try_construct_for_keeper
               ~base_path:config.base_path
               ~agent_name:meta.agent_name
         in
         let cli_subprocess_idle_sec =
           Some (Keeper_runtime_resolved.cli_subprocess_idle_sec ())
         in
         Some
           ({ cwd = Some keeper_sandbox_root
            ; claude_mcp_config
            ; claude_allowed_tools = None
            ; claude_permission_mode = None
            ; claude_max_turns = Some max_turns
            ; gemini_yolo =
                (match approval_mode_effective with
                 | Some mode -> Some (String.equal (String.lowercase_ascii mode) "yolo")
                 | None -> None)
            ; cli_subprocess_idle_sec
            }
            : Cascade_runner.cli_transport_overrides)
       in
       (* Phase 0: wake-time payload telemetry (Option C baseline).
       Entire block is dead code when MASC_PAYLOAD_TELEMETRY is unset.
       Compute logic lives in [Keeper_wake_telemetry] for unit tests;
       exceptions from the telemetry path never abort the LLM call. *)
       let () =
         if Env_config_keeper.KeeperTelemetry.payload_telemetry_enabled ()
         then (
           try
             let sizes =
               Keeper_wake_telemetry.compute_sizes
                 ~system_prompt:turn_system_prompt
                 ~tools
                 ~history_messages
                 ~user_message
             in
             let model_id =
               match meta.models with
               | m :: _ -> m
               | [] -> "auto"
             in
             let _event : Dashboard_harness_health.wake_payload_event =
               Dashboard_harness_health.record_wake_payload
                 ~keeper_name:meta.name
                 ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                 ~turn_index:start_turn_count
                 ~model_id
                 ~context_window:max_context
                 ~approx_body_bytes:sizes.approx_body_bytes
                 ~system_prompt_bytes:sizes.system_prompt_bytes
                 ~tool_defs_bytes:sizes.tool_defs_bytes
                 ~messages_bytes:sizes.messages_bytes
                 ~message_count:sizes.message_count
                 ~role_counts:sizes.role_counts
                 ~tool_count:sizes.tool_count
                 ~has_compact_happened:pre_dispatch_compacted
             in
             ()
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
             Log.Harness.warn
               "[wake_payload] telemetry failed keeper=%s: %s"
               meta.name
               (Printexc.to_string exn))
       in
       let turn_result =
         match pre_dispatch_checkpoint_error with
         | Some err -> Error err
         | None ->
           (match !initial_tool_surface_blocker_ref with
            | Some err -> Error err
            | None ->
              (match
                 Keeper_llm_bridge.run_with_timeout_and_fallback ~timeout_s (fun () ->
                   Keeper_turn_driver.run_named
                     ~cascade_name:cascade_name_string
                     ~keeper_name:meta.name
                     ~model_strings:meta.models
                     ?provider_filter
                     ~require_tool_choice_support
                     ~require_tool_support
                     ~goal:user_message
                     ~priority
                     ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                     ~system_prompt:turn_system_prompt
                     ~tools
                     ~compact_ratio:meta.compaction.ratio_gate
                     ~initial_messages:history_messages
                     ~hooks
                     ~context_reducer:reducer
                     ~summarizer:Keeper_summarizer.keeper_summarizer
                     ~memory
                       (* Keepers use turn-level retry for transient errors but benefit
               from OAS per-call retry for validation errors (malformed tool
               args). retry_on_validation_error=true lets OAS re-prompt the
               LLM with structured feedback instead of wasting a full turn.
               retry_on_recoverable_tool_error remains false — tool-level
               errors are handled by MASC's consecutive failure guardrail. *)
                     ~tool_retry_policy:
                       { Agent_sdk.Tool_retry_policy.max_retries = 2
                       ; retry_on_validation_error = true
                       ; retry_on_recoverable_tool_error = false
                       ; feedback_style =
                           Agent_sdk.Tool_retry_policy.Structured_tool_result
                       }
                     ~required_tool_satisfaction:(fun call ->
                       Keeper_tool_disclosure
                       .required_tool_satisfaction_for_required_names
                         ~required_tool_names:acc.tool_surface.required_tool_names
                         call)
                     ~max_turns
                     ~max_idle_turns
                     ?stream_idle_timeout_s
                     ~temperature
                     ~max_tokens
                     ?max_cost_usd
                     ?wait_timeout_sec:admission_wait_timeout_sec
                     ?guardrails
                     ?on_event
                     ?on_yield
                     ?on_resume
                     ~agent_ref
                     ?contract
                     ?cli_transport_overrides
                     ~allowed_paths:oas_allowed_paths
                     ~cache_system_prompt:true
                     ~yield_on_tool
                     ~checkpoint_dir:session_dir
                     ~context_injector
                     ~context:shared_context
                     ?slot_id:(Keeper_config.keeper_slot_id meta.name)
                     ~approval:
                       (Governance_pipeline.to_oas_approval_callback
                          ~config
                          ~governance_level:(Env_config_core.governance_level ())
                          ~keeper_name:meta.name
                          ~meta
                          ?clock:(Eio_context.get_clock_opt ())
                          ())
                     ~enable_thinking:(Keeper_config.keeper_enable_thinking ())
                       (* exit_condition removed with mutation_boundary — OAS runs to
              natural completion (max_turns or model end_turn). *)
                     ?oas_checkpoint:resume_oas_checkpoint
                     ?event_bus
                     ?per_provider_timeout_s
                     ())
               with
               | Error e -> Error e
               | Ok result ->
                 let post_turn_t0 = Time_compat.now () in
                 (* Checkpoint save is deferred until after [STATE] synthesis so the
           persisted checkpoint includes the synthesized continuity block.
           Without this, read_continuity_summary finds no [STATE] in the
           checkpoint messages and returns empty — causing keepers to lose
           context across turns.  See #5431. *)
                 (* RFC-MASC-004: AfterTurn hooks flush incrementally during
          Agent.run. Post-run episode creation requires an explicit
          flush_incremental call since AfterTurn already fired. *)
                 let text = Agent_sdk.Types.text_of_content result.response.content in
                 let model = result.response.model in
                 receipt_turn_count_ref := Some result.turns;
                 receipt_model_used_ref := Some model;
                 receipt_stop_reason_ref
                 := Some
                      (Keeper_execution_receipt.stop_reason_to_string result.stop_reason);
                 receipt_cascade_observation_ref := result.cascade_observation;
                 (* Extract and persist thinking blocks to trajectory JSONL.
           NOTE: turn = acc.turn stays at 0 in the keeper path because
           Trajectory.increment_turn is never called here — the keeper
           uses OAS Agent.run which manages its own internal call count.
           Consumers should treat turn=0 as "turn not tracked in keeper path". *)
                 (match trajectory_acc with
                  | Some acc ->
                    let now = Time_compat.now () in
                    let now_iso = Masc_domain.now_iso () in
                    List.iter
                      (function
                        | Agent_sdk.Types.Thinking { content; _ } ->
                          let entry : Trajectory.thinking_entry =
                            { ts = now
                            ; ts_iso = now_iso
                            ; turn = acc.Trajectory.turn
                            ; content
                            ; content_length = String.length content
                            ; redacted = false
                            }
                          in
                          (try
                             Trajectory.append_thinking
                               ~masc_root:acc.Trajectory.masc_root
                               ~keeper_name:acc.Trajectory.keeper_name
                               ~trace_id:acc.Trajectory.trace_id
                               entry
                           with
                           | Eio.Cancel.Cancelled _ as e -> raise e
                           | exn ->
                             Log.Keeper.error
                               "keeper:%s thinking persist failed: %s"
                               meta.name
                               (Printexc.to_string exn);
                             Prometheus.inc_counter
                               Keeper_metrics.metric_keeper_thinking_persist_failures
                               ~labels:[ "keeper", meta.name ]
                               ())
                        | Agent_sdk.Types.RedactedThinking _ ->
                          let entry : Trajectory.thinking_entry =
                            { ts = now
                            ; ts_iso = now_iso
                            ; turn = acc.Trajectory.turn
                            ; content = "[redacted]"
                            ; content_length = 0
                            ; redacted = true
                            }
                          in
                          (try
                             Trajectory.append_thinking
                               ~masc_root:acc.Trajectory.masc_root
                               ~keeper_name:acc.Trajectory.keeper_name
                               ~trace_id:acc.Trajectory.trace_id
                               entry
                           with
                           | Eio.Cancel.Cancelled _ as e -> raise e
                           | exn ->
                             Log.Keeper.error
                               "keeper:%s redacted thinking persist failed: %s"
                               meta.name
                               (Printexc.to_string exn);
                             Prometheus.inc_counter
                               Keeper_metrics.metric_keeper_thinking_persist_failures
                               ~labels:[ "keeper", meta.name ]
                               ())
                        | _ -> ())
                      result.response.content
                  | None -> ());
                 let reported_tool_names =
                   List.filter_map
                     (function
                       | Agent_sdk.Types.ToolUse { name; _ } -> Some name
                       | _ -> None)
                     result.response.content
                 in
                 reported_tool_names_ref := reported_tool_names;
                 let tool_usage_after =
                   Keeper_tool_disclosure.keeper_tool_usage_snapshot
                     ~base_path:config.base_path
                     ~keeper_name:meta.name
                 in
                 let registry_observed_tool_names =
                   Keeper_tool_disclosure.tool_usage_delta
                     ~before:tool_usage_before
                     ~after:tool_usage_after
                 in
                 let hook_observed_tool_names =
                   List.rev_map
                     (fun (detail : tool_call_detail) -> detail.tool_name)
                     acc.tool_calls
                 in
                 let observed_tool_names =
                   Keeper_tool_disclosure.merge_observed_tool_names
                     ~registry_observed_tool_names
                     ~hook_observed_tool_names
                 in
                 observed_tool_names_ref := observed_tool_names;
                 let tool_names =
                   Keeper_tool_disclosure.merge_reported_and_observed_tool_names
                     ~reported_tool_names
                     ~observed_tool_names
                 in
                 (* RFC-0006 Phase A.3: canonicalize Anthropic Code built-in names
          (Bash/Read/Edit/Grep/Write) to their keeper_* internal cognates
          before the surface check. Without this, the disclosure check
          flags every Bash/Read call as "unexpected" and nukes turns where
          the LLM only used the alias names (≈18% of turns per #8778).

          Phase A.2 (OAS dual registration) makes the actual call succeed
          end-to-end. This step alone just stops the turn loss. Names with
          no cognate (Skill/Agent/WebSearch) remain unexpected and may
          still trigger a teaching error — see Keeper_tool_alias.is_hallucinated_builtin. *)
                 let canonical_tool_names =
                   Keeper_tool_alias.canonicalize_observed_with_telemetry tool_names
                 in
                 canonical_tool_names_ref := canonical_tool_names;
                 let unexpected_tool_names =
                   Keeper_tool_disclosure.unexpected_tool_names
                     ~allowed_tool_names:all_tool_names
                     ~tool_names:canonical_tool_names
                 in
                 unexpected_tool_names_ref := unexpected_tool_names;
                 (* Partial tolerance (#8471): when a turn mixes valid tool calls
          with unexpected ones (LLM hallucinating Claude Code built-ins
          like Bash/Read/Skill outside the keeper surface), do not nuke
          the whole turn. OAS already returns tool_result="error" for the
          unknown calls so the LLM can recover on the next step. We still
          hard-fail when EVERY tool call is unexpected — that means the
          turn produced no valid work. See feedback memory
          feedback_tool-error-messages-teach-llm.md. *)
                 let valid_tool_calls_present =
                   Keeper_tool_disclosure.has_valid_tool_call
                     ~unexpected_tool_names
                     ~tool_names:canonical_tool_names
                 in
                 if valid_tool_calls_present then acc.keeper_surface_tool_used <- true;
                 if unexpected_tool_names <> [] && not valid_tool_calls_present
                 then (
                   let reason =
                     Printf.sprintf
                       "keeper turn reported unexpected tool names outside keeper \
                        surface: %s"
                       (String.concat ", " unexpected_tool_names)
                   in
                   acc.receipt_tool_contract_result <- "violated";
                   Prometheus.inc_counter
                     Keeper_metrics.metric_keeper_contract_violations
                     ~labels:
                       [ "keeper_name", meta.name
                       ; "kind", "tool_surface_violation"
                       ; "signal", "unexpected_tool_names"
                       ]
                     ();
                   Log.Keeper.error
                     "keeper:%s cascade=%s %s"
                     meta.name
                     (Keeper_types.cascade_name_of_meta meta)
                     reason;
                   Error (Agent_sdk.Error.Internal reason))
                 else (
                   let should_log_unexpected_tool_partial =
                     unexpected_tool_names <> []
                     && should_log_unexpected_tool_partial_once
                          ~keeper_name:meta.name
                          ~unexpected_tool_names
                   in
                   if unexpected_tool_names <> []
                   then
                     Prometheus.inc_counter
                       Keeper_metrics.metric_keeper_unexpected_tool_partial_tolerance
                       ~labels:
                         [ "keeper_name", meta.name
                         ; "logged", string_of_bool should_log_unexpected_tool_partial
                         ]
                       ();
                   if should_log_unexpected_tool_partial
                   then
                     Log.Keeper.warn
                       "keeper:%s unexpected_tool_partial_tolerance tools=%s (cycle \
                        continues; valid tools present)"
                       meta.name
                       (String.concat ", " unexpected_tool_names);
                   let actual_keeper_tool_names =
                     Keeper_tool_disclosure.final_keeper_tool_names
                       ~reported_tool_names
                       ~observed_tool_names
                       ~allowed_tool_names:all_tool_names
                   in
                   actual_keeper_tool_names_ref := actual_keeper_tool_names;
                   let usage = Keeper_exec_context.usage_of_response result.response in
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
                   (* Classify the most-specific actionable signal from the structured
            keeper world snapshot. This deliberately avoids re-parsing the
            rendered prompt text; prompt copy may change without changing the
            deterministic contract gate. *)
                   let actionable_signal_kind
                     : Keeper_contract_classifier.actionable_signal
                     =
                     match world_observation with
                     | None -> No_actionable_signal
                     | Some observation ->
                       observation
                       |> Keeper_contract_classifier.of_keeper_world_observation
                       |> Keeper_contract_classifier.classify_actionable_signal_for_tools
                            ~allowed_tool_names:all_tool_names
                   in
                   let actionable_signal_context =
                     Keeper_agent_tool_surface
                     .turn_affordances_require_tool_gate_with_allowed
                       ~allowed_tool_names:all_tool_names
                       turn_affordances
                     || Keeper_contract_classifier.is_actionable actionable_signal_kind
                   in
                   let actionable_tool_contract_violation_reason =
                     Keeper_tool_disclosure.actionable_tool_contract_violation_reason
                       ~claim_context_allowed:(not had_owned_active_task_at_turn_start)
                       ~actionable_signal_context
                       ~tool_names:actual_keeper_tool_names
                   in
                   let contract_violation_error reason =
                     Agent_sdk.Error.Agent
                       (Agent_sdk.Error.CompletionContractViolation
                          { contract = Agent_sdk.Completion_contract_id.Require_tool_use
                          ; reason
                          })
                   in
                   let tool_contract_status () =
                     let required_tool_names = acc.tool_surface.required_tool_names in
                     let missing_visible_required =
                       acc.tool_surface.missing_required_tool_names
                     in
                     let class_of name =
                       Keeper_tool_disclosure.classify_tool_progress name
                     in
                     let classes = List.map class_of actual_keeper_tool_names in
                     let has_class wanted = List.exists (( = ) wanted) classes in
                     let all_class wanted =
                       classes <> [] && List.for_all (( = ) wanted) classes
                     in
                     let all_required_used =
                       List.for_all
                         (fun name -> List.mem name actual_keeper_tool_names)
                         required_tool_names
                     in
                     if missing_visible_required <> []
                     then "tool_surface_mismatch"
                     else if required_tool_names <> [] && not all_required_used
                     then
                       if actual_keeper_tool_names = []
                       then "missing_required_tool_use"
                       else if
                         all_class Keeper_tool_disclosure.Claim_context
                         && had_owned_active_task_at_turn_start
                       then "claim_only_after_owned_task"
                       else if all_class Keeper_tool_disclosure.Claim_context
                       then "needs_execution_progress"
                       else if all_class Keeper_tool_disclosure.Passive_status
                       then "passive_only"
                       else "missing_required_tool_use"
                     else if actual_keeper_tool_names = []
                     then "satisfied_completion"
                     else if
                       all_class Keeper_tool_disclosure.Claim_context
                       && had_owned_active_task_at_turn_start
                     then "claim_only_after_owned_task"
                     else if all_class Keeper_tool_disclosure.Claim_context
                     then "needs_execution_progress"
                     else if all_class Keeper_tool_disclosure.Passive_status
                     then "passive_only"
                     else if has_class Keeper_tool_disclosure.Completion
                     then "satisfied_completion"
                     else if has_class Keeper_tool_disclosure.Execution
                     then "satisfied_execution"
                     else "needs_execution_progress"
                   in
                   (* Required-tool turns are filtered onto providers that declare
            tool support plus tool_choice support. If a text-only response
            still reaches this point, treat it as a contract failure. *)
                   let text_result =
                     let effective_completion_contract =
                       Keeper_tool_disclosure.run_completion_contract
                         ~turn_contract:acc.completion_contract
                         ~required_tool_use_seen:acc.required_tool_use_seen
                     in
                     match
                       ( Keeper_tool_disclosure.validate_completion_contract_presence
                           ~contract:effective_completion_contract
                           ~tool_present:acc.keeper_surface_tool_used
                       , actionable_tool_contract_violation_reason )
                     with
                     | Ok (), Some reason ->
                       let contract_status =
                         if actual_keeper_tool_names = []
                         then "missing_required_tool_use"
                         else tool_contract_status ()
                       in
                       acc.receipt_tool_contract_result <- contract_status;
                       (* #10091: emit the labelled counter so dashboards
                  can distinguish the [has_current_task=true]
                  strict-gate path (#10031 kept this intentionally
                  strict) from the [has_current_task=false] path
                  (already relaxed to [Auto]).  The strict gate
                  behaviour is unchanged — this is pure
                  observability that lets the operator pinpoint
                  which (keeper, contract_status) pairs are
                  config-mismatched. *)
                       Keeper_tool_disclosure.record_require_tool_use_violation
                         ~keeper_name:meta.name
                         ~has_current_task:(keeper_has_owned_active_task ())
                         ~contract_status;
                       let signal_label =
                         Keeper_contract_classifier.actionable_signal_label
                           actionable_signal_kind
                       in
                       Log.Keeper.error
                         "keeper:%s required tool contract violated (turn=%d, tools=%d, \
                          signal=%s). Rejecting no-op/passive actionable turn. Reason: \
                          %s"
                         meta.name
                         result.turns
                         (List.length actual_keeper_tool_names)
                         signal_label
                         reason;
                       Prometheus.inc_counter
                         Keeper_metrics.metric_keeper_contract_violations
                         ~labels:
                           [ "keeper_name", meta.name
                           ; "kind", "passive"
                           ; "signal", signal_label
                           ]
                         ();
                       Error (contract_violation_error reason)
                     | Ok (), None ->
                       acc.receipt_tool_contract_result <- tool_contract_status ();
                       Ok (`Provider_text text)
                     | Error reason, _ ->
                       let contract_status =
                         if actual_keeper_tool_names = []
                         then "missing_required_tool_use"
                         else tool_contract_status ()
                       in
                       acc.receipt_tool_contract_result <- contract_status;
                       Keeper_tool_disclosure.record_require_tool_use_violation
                         ~keeper_name:meta.name
                         ~has_current_task:(keeper_has_owned_active_task ())
                         ~contract_status;
                       let contract_str =
                         match effective_completion_contract with
                         | Keeper_tool_disclosure.Allow_text_or_tool ->
                           "Allow_text_or_tool"
                         | Keeper_tool_disclosure.Require_tool_use -> "Require_tool_use"
                       in
                       let signal_label =
                         Keeper_contract_classifier.actionable_signal_label
                           actionable_signal_kind
                       in
                       Log.Keeper.error
                         "keeper:%s required tool contract violated (turn=%d, tools=%d, \
                          contract=%s, signal=%s). Rejecting text-only response. Reason: \
                          %s"
                         meta.name
                         result.turns
                         (List.length actual_keeper_tool_names)
                         contract_str
                         signal_label
                         reason;
                       Prometheus.inc_counter
                         Keeper_metrics.metric_keeper_contract_violations
                         ~labels:
                           [ "keeper_name", meta.name
                           ; "kind", "text_only"
                           ; "signal", signal_label
                           ]
                         ();
                       Error (contract_violation_error reason)
                   in
                   let finalize_response_text raw_response_text =
                     let stop_reason_str =
                       match result.stop_reason with
                       | Cascade_runner.Completed -> "completed"
                       | Cascade_runner.TurnBudgetExhausted _ -> "budget_exhausted"
                       | Cascade_runner.MutationBoundaryReached { tool_name; _ } ->
                         (match tool_name with
                          | Some tool -> Printf.sprintf "mutation_boundary(%s)" tool
                          | None -> "mutation_boundary")
                     in
                     let state_snapshot =
                       match
                         Keeper_memory_policy.parse_state_snapshot_from_reply
                           raw_response_text
                       with
                       | Some snapshot -> snapshot
                       | None ->
                         let final_tool_names =
                           match !actual_keeper_tool_names_ref with
                           | [] -> actual_keeper_tool_names
                           | names -> names
                         in
                         let synth =
                           Keeper_memory_policy.synthesize_state_from_run_result
                             ~goal:meta.goal
                             ~tools_used:final_tool_names
                             ~stop_reason:stop_reason_str
                             ~response_text:raw_response_text
                         in
                         Log.Keeper.info
                           "keeper:%s [STATE] missing, synthesized from %d tools \
                            (stop=%s)"
                           meta.name
                           (List.length final_tool_names)
                           stop_reason_str;
                         synth
                     in
                     let response_text =
                       match
                         Keeper_text_processing.state_snapshot_reply_fallback
                           (Some state_snapshot)
                       with
                       | Some fallback ->
                         Keeper_text_processing.user_visible_reply_text
                           ~fallback
                           raw_response_text
                       | None ->
                         Keeper_text_processing.user_visible_reply_text raw_response_text
                     in
                     receipt_response_text_present_ref := true;
                     let assistant_msg =
                       Agent_sdk.Types.make_message
                         ~role:Agent_sdk.Types.Assistant
                         ~metadata:
                           [ ( Keeper_memory_policy.replay_metadata_key
                             , Keeper_memory_policy.replay_metadata_of_snapshot
                                 state_snapshot )
                           ]
                         [ Agent_sdk.Types.Text response_text ]
                     in
                     Keeper_exec_context.persist_message
                       ~source:history_assistant_source
                       session
                       assistant_msg;
                     (* ctx_snapshot is immutable — assistant message is persisted
                 via checkpoint (OAS) and persist_message (history file).
                 No in-memory mutation needed; next turn reconstructs
                 context from checkpoint. *)
                     (* Save checkpoint after extracting the replay snapshot so the
                 persisted checkpoint carries scrubbed assistant text plus
                 structured replay metadata on the last assistant message. *)
                     let saved_checkpoint_result =
                       match result.checkpoint with
                       | Some checkpoint ->
                         let patched =
                           Keeper_context_core.patch_checkpoint_last_assistant
                             checkpoint
                             ~session_id:
                               (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                             ~response_text
                             ~snapshot:state_snapshot
                         in
                         (match
                            Keeper_checkpoint_store.save_oas
                              ~session_dir:session.session_dir
                              patched
                          with
                          | Ok () -> Ok (Some patched)
                          | Error e ->
                            Log.Keeper.error
                              "keeper:%s cascade=%s OAS checkpoint save failed: %s"
                              meta.name
                              (Keeper_types.cascade_name_of_meta meta)
                              e;
                            Prometheus.inc_counter
                              Keeper_metrics.metric_keeper_checkpoint_failures
                              ~labels:[ "keeper", meta.name; "site", "save" ]
                              ();
                            Error
                              (checkpoint_persistence_error
                                 ~keeper_name:meta.name
                                 ~detail:("OAS checkpoint save failed: " ^ e)))
                       | None ->
                         Log.Keeper.error
                           "keeper:%s cascade=%s missing OAS checkpoint after run"
                           meta.name
                           (Keeper_types.cascade_name_of_meta meta);
                         Prometheus.inc_counter
                           Keeper_metrics.metric_keeper_checkpoint_failures
                           ~labels:[ "keeper", meta.name; "site", "missing" ]
                           ();
                         Error
                           (checkpoint_persistence_error
                              ~keeper_name:meta.name
                              ~detail:"missing OAS checkpoint after run")
                     in
                     match saved_checkpoint_result with
                     | Error e -> Error e
                     | Ok saved_checkpoint ->
                       (match result.proof with
                        | Some p ->
                          Keeper_turn_telemetry.log_keeper_proof ~keeper_name:meta.name p;
                          let store = Masc_mcp_cdal_runtime.Proof_store.default_config in
                          let outcome = Cdal_eval_v1.evaluate ~store p in
                          let verdict = Cdal_eval_v1.verdict_of_outcome outcome in
                          let task_subject =
                            Option.map
                              (fun task_id ->
                                 Coord_hooks.
                                   { kind = "task"
                                   ; id = Keeper_id.Task_id.to_string task_id
                                   })
                              acc.meta.current_task_id
                          in
                          let emit_keeper_activity ~kind ~payload ~tags =
                            try
                              (Atomic.get Coord_hooks.activity_emit_fn)
                                config
                                ~actor:
                                  Coord_hooks.{ kind = "agent"; id = meta.agent_name }
                                ?subject:task_subject
                                ~kind
                                ~payload
                                ~tags
                                ()
                            with
                            | Eio.Cancel.Cancelled _ as e -> raise e
                            | exn ->
                              Prometheus.inc_counter
                                Keeper_metrics.metric_keeper_dispatch_event_failures
                                ~labels:[ "keeper", meta.name; "site", "activity_emit" ]
                                ();
                              Log.Keeper.warn
                                "keeper:%s activity emit failed (%s): %s"
                                meta.name
                                kind
                                (Printexc.to_string exn)
                          in
                          let task_id =
                            Option.map
                              Keeper_id.Task_id.to_string
                              acc.meta.current_task_id
                          in
                          Cdal_eval_v1.persist ?task_id verdict;
                          Keeper_turn_telemetry.log_keeper_contract_verdict
                            ~keeper_name:meta.name
                            verdict;
                          emit_keeper_activity
                            ~kind:"keeper.contract_verdict"
                            ~payload:
                              (Keeper_turn_telemetry.contract_verdict_activity_payload
                                 ~keeper_name:meta.name
                                 verdict)
                            ~tags:
                              ([ "keeper"
                               ; "cdal"
                               ; "contract_verdict"
                               ; Cdal_types.contract_status_to_string verdict.status
                               ]
                               @
                               if
                                 List.exists
                                   (fun (gap : Cdal_types.completeness_gap) ->
                                      String.equal
                                        gap.artifact
                                        "evidence/review_warning.json")
                                   verdict.completeness_gaps
                               then [ "review_requirement" ]
                               else []);
                          (match outcome with
                           | Cdal_eval_v1.Load_failure (err, _) ->
                             Prometheus.inc_counter
                               Keeper_metrics.metric_keeper_dispatch_event_failures
                               ~labels:[ "keeper", meta.name; "site", "cdal_load" ]
                               ();
                             Log.Keeper.warn
                               "keeper:%s contract_verdict load failure: %s"
                               meta.name
                               (Cdal_loader.load_error_to_string err)
                           | Cdal_eval_v1.Verdict (_, _) -> ());
                          (match Cdal_eval_v1.friction_of_outcome outcome with
                           | Some fp ->
                             Keeper_turn_telemetry.log_keeper_friction
                               ~keeper_name:meta.name
                               fp;
                             emit_keeper_activity
                               ~kind:"keeper.friction"
                               ~payload:
                                 (Keeper_turn_telemetry.friction_activity_payload
                                    ~keeper_name:meta.name
                                    fp)
                               ~tags:
                                 ([ "keeper"; "cdal"; "friction" ]
                                  @
                                  if fp.review_tripwires <> [] then [ "tripwire" ] else []
                                 )
                           | None -> ())
                        | None -> ());
                       (* Post-turn deterministic memory write.
             Uses meta-based fallback when [STATE] parsing fails.
             See RFC #3646 Section 3: Det/NonDet boundary. *)
                       (try
                          let notes_written, kinds_written =
                            Keeper_memory_bank.append_memory_notes_from_reply
                              config
                              meta
                              ~snapshot:state_snapshot
                              ~turn:result.turns
                              ~reply:response_text
                              ()
                          in
                          let tool_result_notes_written =
                            if Keeper_tool_emission_hook.masc_tool_emission_enabled ()
                            then (
                              let tool_results =
                                Keeper_tool_emission_hook.(
                                  snapshot (accumulator_for_keeper meta.name))
                              in
                              Keeper_memory_bank.append_memory_notes_from_tool_results
                                config
                                meta
                                ~turn:result.turns
                                ~results:tool_results)
                            else 0
                          in
                          let notes_written = notes_written + tool_result_notes_written in
                          let kinds_written =
                            if
                              tool_result_notes_written > 0
                              && not (List.mem "long_term" kinds_written)
                            then kinds_written @ [ "long_term" ]
                            else kinds_written
                          in
                          if notes_written > 0
                          then
                            Keeper_turn_telemetry.log_keeper_memory_write
                              ~keeper_name:meta.name
                              ~notes_written
                              ~kinds_written
                        with
                        | exn ->
                          Log.Keeper.error
                            "keeper:%s memory_write failed: %s"
                            meta.name
                            (Printexc.to_string exn);
                          Prometheus.inc_counter
                            Keeper_metrics.metric_keeper_memory_write_failures
                            ~labels:[ "keeper", meta.name ]
                            ());
                       (* Episodic memory: create an episode from [STATE] after
              Agent.run returns, then persist and emit activity through the
              post-run memory adapter. Collaboration learning (Hebbian
              strengthen/weaken) is owned by the task lifecycle path. *)
                       Keeper_agent_memory_episode.record_success
                         ~config
                         ~keeper_name:meta.name
                         ~memory
                         ~turn:result.turns
                         ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                         ~snapshot:state_snapshot
                         ();
                       (* Memory bank compaction: dedup + consolidate if over threshold. *)
                       (try
                          let compaction =
                            Keeper_memory_bank.compact_memory_bank_if_needed config meta
                          in
                          if compaction.performed
                          then
                            Log.Keeper.info
                              "keeper:%s memory_compacted before=%d after=%d dropped=%d"
                              meta.name
                              compaction.before_notes
                              compaction.after_notes
                              compaction.dropped_notes
                        with
                        | Eio.Cancel.Cancelled _ as e -> raise e
                        | exn ->
                          Prometheus.inc_counter
                            Keeper_metrics.metric_keeper_dispatch_event_failures
                            ~labels:[ "keeper", meta.name; "site", "compaction" ]
                            ();
                          Log.Keeper.warn
                            "keeper:%s cascade=%s compaction failed: %s"
                            meta.name
                            (Keeper_types.cascade_name_of_meta meta)
                            (Printexc.to_string exn));
                       (* Post-turn quality metrics — goal alignment + memory recall.
             Logged to decisions.jsonl for feedback loop analysis. *)
                       (try
                          let goal_score =
                            Keeper_memory_recall.goal_alignment_score
                              ~meta
                              ~user_message:None
                              ~assistant_reply:(Some response_text)
                          in
                          let used_search =
                            List.exists
                              (fun t -> t = "keeper_memory_search")
                              actual_keeper_tool_names
                          in
                          let recall_eval =
                            if used_search
                            then (
                              let bank_path =
                                Keeper_types_support.keeper_memory_bank_path
                                  config
                                  meta.name
                              in
                              let candidates =
                                try
                                  Keeper_memory_recall.load_history_user_messages
                                    ~path:bank_path
                                    ~max_n:50
                                with
                                | Eio.Cancel.Cancelled _ as e -> raise e
                                | exn ->
                                  Prometheus.inc_counter
                                    Keeper_metrics.metric_keeper_dispatch_event_failures
                                    ~labels:
                                      [ "keeper", meta.name; "site", "memory_recall" ]
                                    ();
                                  Log.Keeper.warn
                                    "keeper:%s memory recall history load failed: %s"
                                    meta.name
                                    (Printexc.to_string exn);
                                  []
                              in
                              Some
                                (Keeper_memory_recall.evaluate_memory_recall
                                   ~user_message:""
                                   ~assistant_reply:response_text
                                   ~candidates))
                            else None
                          in
                          let post_turn_ms =
                            Keeper_timing.round1
                              ((Time_compat.now () -. post_turn_t0) *. 1000.0)
                          in
                          let eval_json =
                            `Assoc
                              ([ "ts_unix", `Float (Time_compat.now ())
                               ; "event", `String "post_turn_eval"
                               ; "keeper_name", `String meta.name
                               ; "turn", `Int result.turns
                               ; "goal_alignment", `Float goal_score
                               ; ( "tools_used_count"
                                 , `Int (List.length actual_keeper_tool_names) )
                               ; "used_memory_search", `Bool used_search
                               ; "post_turn_ms", `Float post_turn_ms
                               ]
                               @ (match result.response.telemetry with
                                  | Some t ->
                                    [ ( "inference_telemetry"
                                      , Agent_sdk.Types.inference_telemetry_to_yojson t )
                                    ]
                                  | None -> [])
                               @
                               match recall_eval with
                               | Some e ->
                                 [ "memory_recall_performed", `Bool e.performed
                                 ; "memory_recall_passed", `Bool e.passed
                                 ; "memory_recall_score", `Float e.final_score
                                 ; "memory_recall_candidates", `Int e.candidate_count
                                 ]
                               | None -> [])
                          in
                          Keeper_types_support.append_jsonl_line
                            (Keeper_types_support.keeper_decision_log_path
                               config
                               meta.name)
                            eval_json
                        with
                        | Eio.Cancel.Cancelled _ as e -> raise e
                        | exn ->
                          Prometheus.inc_counter
                            Keeper_metrics.metric_keeper_dispatch_event_failures
                            ~labels:[ "keeper", meta.name; "site", "post_turn_eval" ]
                            ();
                          Log.Keeper.warn
                            "keeper:%s post_turn_eval jsonl append failed: %s"
                            meta.name
                            (Printexc.to_string exn));
                       Ok
                         { response_text
                         ; model_used = model
                         ; prompt_metrics
                         ; ctx_composition
                         ; cascade_observation = result.cascade_observation
                         ; turn_count = result.turns
                         ; tool_calls_made = List.length actual_keeper_tool_names
                         ; usage
                         ; usage_reported = Option.is_some result.response.usage
                         ; tools_used = actual_keeper_tool_names
                         ; tool_calls = List.rev acc.tool_calls
                         ; checkpoint = saved_checkpoint
                         ; proof = result.proof
                         ; trace_ref = result.trace_ref
                         ; run_validation = result.run_validation
                         ; stop_reason = result.stop_reason
                         ; inference_telemetry = result.response.telemetry
                         ; tool_surface = acc.tool_surface
                         }
                   in
                   match text_result with
                   | Error e -> Error e
                   | Ok (`Provider_text text) ->
                     (match
                        Keeper_tool_disclosure.normalize_response_text
                          ~text
                          ~tool_names:actual_keeper_tool_names
                          ()
                      with
                      | Error e -> Error (Agent_sdk.Error.Internal e)
                      | Ok response_text -> finalize_response_text response_text))))
       in
       (match turn_result with
        | Ok _ -> ()
        | Error err ->
          let turn =
            match !receipt_turn_count_ref with
            | Some turns -> turns
            | None -> start_turn_count + 1
          in
          Keeper_agent_memory_episode.record_failure
            ~config
            ~keeper_name:meta.name
            ~memory
            ~turn
            ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
            ~error_kind:(Memory_oas_bridge.error_kind_of_string (sdk_error_kind err))
            ~error_message:(Agent_sdk.Error.to_string err)
            ());
       let receipt_ended_at = Masc_domain.now_iso () in
       let error_kind, error_message =
         match turn_result with
         | Ok _ -> None, None
         | Error err ->
           ( Some (Keeper_execution_receipt.error_kind_of_string (sdk_error_kind err))
           , Some (Agent_sdk.Error.to_string err) )
       in
       let tool_contract_result =
         match turn_result with
         | Error (Agent_sdk.Error.Agent (Agent_sdk.Error.CompletionContractViolation _))
           ->
           if String.equal acc.receipt_tool_contract_result "unknown"
           then "violated"
           else acc.receipt_tool_contract_result
         | _ -> acc.receipt_tool_contract_result
       in
       let terminal_reason_code =
         match turn_result with
         | Ok _ ->
           (* RFC-0047 PR-4: emit canonical "success" wire directly. Pre-PR-4
           this defaulted to "completed", which [Keeper_turn_terminal.normalize_code]
           remapped to "success" before disposition lookup. The producer-side
           default is now the canonical wire; the normalize step is gone. *)
           Option.value ~default:"success" !receipt_stop_reason_ref
         | Error err -> terminal_reason_code_of_sdk_error err
       in
       let cascade_observation = !receipt_cascade_observation_ref in
       let receipt =
         { Keeper_execution_receipt.keeper_name = meta.name
         ; agent_name = meta.agent_name
         ; trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id
         ; generation
         ; turn_count = !receipt_turn_count_ref
         ; current_task_id =
             Option.map Keeper_id.Task_id.to_string acc.meta.current_task_id
         ; goal_ids = meta.active_goal_ids
         ; outcome =
             (match turn_result with
              | Ok _ -> Keeper_execution_receipt.outcome_kind_to_string `Ok
              | Error err ->
                Keeper_execution_receipt.outcome_kind_to_string
                  (receipt_outcome_kind_of_sdk_error err))
         ; terminal_reason_code
         ; response_text_present = !receipt_response_text_present_ref
         ; model_used = !receipt_model_used_ref
         ; requested_tools = acc.requested_tool_names
         ; reported_tools = !reported_tool_names_ref
         ; observed_tools = !observed_tool_names_ref
         ; canonical_tools = !canonical_tool_names_ref
         ; unexpected_tools = !unexpected_tool_names_ref
         ; tools_used = !actual_keeper_tool_names_ref
         ; tool_contract_result
         ; tool_surface =
             { turn_lane = acc.tool_surface.turn_lane
             ; tool_surface_class = acc.tool_surface.tool_surface_class
             ; tool_requirement = acc.tool_surface.tool_requirement
             ; visible_tool_count = acc.tool_surface.visible_tool_count
             ; tool_gate_enabled = acc.tool_surface.tool_gate_enabled
             ; tool_surface_fallback_used = acc.tool_surface.tool_surface_fallback_used
             ; required_tools = acc.tool_surface.required_tool_names
             ; missing_required_tools = acc.tool_surface.missing_required_tool_names
             }
         ; sandbox_kind = Keeper_execution_receipt.sandbox_kind_of_meta meta
         ; sandbox_root = Some keeper_visible_sandbox_root
         ; network_mode = Keeper_types.network_mode_to_string meta.network_mode
         ; approval_profile = acc.tool_surface.approval_mode_effective
         ; approval_profile_derived = acc.tool_surface.approval_mode_derived
         ; cascade_name
         ; cascade_selected_model =
             Option.bind cascade_observation (fun obs -> obs.selected_model)
         ; cascade_attempt_count =
             (match cascade_observation with
              | Some obs -> List.length obs.attempts
              | None -> 0)
         ; cascade_fallback_applied =
             (match cascade_observation with
              | Some obs -> obs.fallback_applied
              | None -> false)
         ; cascade_outcome = cascade_outcome_of_observation cascade_observation
         ; degraded_retry_applied
         ; degraded_retry_cascade =
             Option.map
               Keeper_execution_receipt.cascade_name_of_string
               degraded_retry_cascade
         ; fallback_reason
         ; cascade_rotation_attempts
         ; stop_reason = !receipt_stop_reason_ref
         ; error_kind
         ; error_message
         ; started_at = receipt_started_at
         ; ended_at = receipt_ended_at
         }
       in
       (* Tier A2 / Cycle 5: receipt append failure escalates to a
       turn-level Error.

       Pre-Cycle 5 the catch arm logged a WARN, recorded a coverage-gap
       and let [turn_result] fall through unchanged. That violates the
       [EveryTurnHasTerminalReceipt] safety property (KeeperTurnFSM
       and KeeperOutcomesConservation specs): a turn whose authoritative
       receipt is silently dropped cannot be reported as Ok. The
       coverage-gap helper is still called so the gap surface keeps
       working; the difference is the caller now sees the failure too. *)
       let receipt_append_outcome : (unit, string) result =
         try
           Keeper_execution_receipt.append config receipt;
           Ok ()
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           let err_msg = Printexc.to_string exn in
           Prometheus.inc_counter
             Keeper_metrics.metric_keeper_dispatch_event_failures
             ~labels:[ "keeper", meta.name; "site", "receipt_append" ]
             ();
           Log.Keeper.warn
             "keeper:%s execution_receipt append failed: %s"
             meta.name
             err_msg;
           (try
              let masc_root = Coord.masc_root_dir config in
              Telemetry_coverage_gap.record
                ~masc_root
                ~source:"execution_receipt"
                ~producer:"keeper_agent_run.execution_receipt"
                ~durable_store:
                  (Filename.concat
                     (Filename.concat (Filename.concat masc_root "keepers") meta.name)
                     "execution-receipts")
                ~dashboard_surface:"/api/v1/dashboard/execution-trust"
                ~stale_reason:"execution_receipt_append_failed"
                ~keeper_name:meta.name
                ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                ~error:err_msg
                ()
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | gap_exn ->
              Prometheus.inc_counter
                Keeper_metrics.metric_keeper_dispatch_event_failures
                ~labels:[ "keeper", meta.name; "site", "coverage_gap_append" ]
                ();
              Log.Keeper.warn
                "keeper:%s execution_receipt coverage gap append failed: %s"
                meta.name
                (Printexc.to_string gap_exn));
           Error err_msg
       in
       (match turn_result, receipt_append_outcome with
        | Error _, _ ->
          (* Turn already failed; preserve the original error rather than
         masking it with a receipt-lost wrapper. The coverage-gap record
         above keeps the receipt-store side observable. *)
          turn_result
        | Ok _, Ok () -> turn_result
        | Ok _, Error err_msg ->
          (* Safety escalation: turn-body succeeded but the authoritative
         receipt could not be persisted. Surface a structured internal
         error so the caller's [match turn_result with Ok _ | Error _]
         no longer sees a fictitious success. *)
          Error
            (Agent_sdk.Error.Internal
               (Printf.sprintf "execution_receipt_append_failed: %s" err_msg))))
;;
