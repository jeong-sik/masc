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

let no_progress_success_tool_names_for_contract =
  Contract_helpers.no_progress_success_tool_names_for_contract
;;

let should_require_provider_tool_choice_support =
  Turn_helpers.should_require_provider_tool_choice_support

let tool_contract_result_for_observed_tools =
  Turn_helpers.tool_contract_result_for_observed_tools

module For_testing = struct
  let sse_event_progress_kind = Turn_helpers.sse_event_progress_kind
  let registry_progress_on_event = Turn_helpers.registry_progress_on_event
  let select_cdal_proof = Turn_helpers.select_cdal_proof
  let cdal_task_id_for_verdict = Contract_helpers.cdal_task_id_for_verdict
  let cdal_verdict_persist_decision = Contract_helpers.cdal_verdict_persist_decision
  let progress_keeper_tool_names_for_contract =
    Contract_helpers.progress_keeper_tool_names_for_contract
  let no_progress_success_tool_names_for_contract =
    Contract_helpers.no_progress_success_tool_names_for_contract
end

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
      ~(cascade_name : Cascade_name.t)
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
      ?(oas_timeout_is_explicit = true)
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
  (* Section 1: Setup — sanitize input, build context, compose prompt. *)
  let user_message = Keeper_run_prompt.sanitize_user_message user_message in
  Masc_runtime_events.emit_turn_start ();
  Memory_hooks.clear_last_memory_injection meta.agent_name;
  (* Cancel-safe cleanup (#9747): stdlib [Fun.protect] wraps finally
     exceptions in [Fun.Finally_raised], masking the outer
     [Eio.Cancel.Cancelled] raised by the turn body during fleet-wide
     cancellation. Swallow Cancelled in the finally (the outer one is
     already in flight) and log non-cancel exceptions instead of
     propagating them. Mirrors the pattern used in
     [keeper_unified_turn.ml] (#9747 iter 1). *)
  let safe_emit_turn_end =
    Turn_helpers.emit_turn_end_safely ~keeper_name:meta.name
  in
  Eio_guard.protect ~finally:safe_emit_turn_end
  @@ fun () ->
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
     children, so cascade attempts and tool invocations spawned inside
     the turn body all see [turn_sw] automatically. *)
  Eio.Switch.run @@ fun turn_sw ->
  Eio_context.with_turn_switch turn_sw
  @@ fun () ->
  let cascade_name_string = Cascade_name.to_string cascade_name in
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
  let meta = ctx.meta in
  let temperature = ctx.temperature in
  let max_output_ceiling =
    Cascade_runtime.max_output_tokens_ceiling_of_cascade_name cascade_name
  in
  let max_tokens, pre_dispatch_max_tokens_error =
    match
      Cascade_inference.validate_max_tokens_within_ceiling
        ~cascade_name
        ~provider_ceiling:max_output_ceiling
        ctx.max_tokens
    with
    | Ok max_tokens -> max_tokens, None
    | Error internal_error ->
      let detail =
        Option.value
          ~default:(Cascade_error_classify.kind_of_masc_internal_error internal_error)
          (Cascade_error_classify.summary_of_masc_internal_error internal_error)
      in
      Log.Keeper.error "%s: %s" meta.name detail;
      ( ctx.max_tokens,
        Some (Cascade_error_classify.sdk_error_of_masc_internal_error internal_error) )
  in
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
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let manifest_keeper_turn_id = meta.runtime.usage.total_turns + 1 in
  let turn_start = Mtime_clock.now () in
  let seq_ref = ref 0 in
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
      ~cascade_name:cascade_name_string
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
            ("context_digest", `String context_digest);
          ]))
    Keeper_runtime_manifest.Context_injected;
  let actionable_signal =
    match world_observation with
    | None -> false
    | Some wo ->
      wo
      |> Keeper_contract_classifier.of_keeper_world_observation
      |> Keeper_contract_classifier.classify_actionable_signal
      |> Keeper_contract_classifier.is_actionable
  in
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
      ~actionable_signal
      ?max_cost_usd
      ~trajectory_acc
      ~tool_overlay
      ~runtime_manifest_context
      ~runtime_manifest_append:
        (Keeper_runtime_manifest.append_best_effort
           ~site:"memory_hooks"
           config)
      ()
  in
  (* Section 2: Tool surface — select tools, compute surface, validate contracts. *)
  match setup with
  | Error e -> Error e
  | Ok s ->
    let cleanup_agent_setup () =
      Turn_helpers.cleanup_agent_setup ~keeper_name:meta.name s
    in
    Turn_helpers.run_with_setup_cleanup ~cleanup:cleanup_agent_setup
    @@ fun () ->
    let tools = s.Keeper_run_tools.tools in
    let hooks = s.Keeper_run_tools.hooks in
    let reducer = s.Keeper_run_tools.reducer in
    let memory = s.Keeper_run_tools.memory in
    let acc = s.Keeper_run_tools.acc in
    append_manifest ~site:"tool_surface_selected"
      ~keeper_turn_id:manifest_keeper_turn_id
      ~decision:
        (`Assoc
          [
            ("turn_lane", `String (turn_lane_to_string acc.tool_surface.turn_lane));
            ( "tool_surface_class",
              `String
                (tool_surface_class_to_string
                   acc.tool_surface.tool_surface_class) );
            ( "tool_requirement",
              `String
                (tool_requirement_to_string acc.tool_surface.tool_requirement)
            );
            ("visible_tool_count", `Int acc.tool_surface.visible_tool_count);
            ("tool_gate_enabled", `Bool acc.tool_surface.tool_gate_enabled);
            ( "tool_surface_fallback_used",
              `Bool acc.tool_surface.tool_surface_fallback_used );
            ( "required_tool_names",
              `List
                (List.map
                   (fun name -> `String name)
                   acc.tool_surface.required_tool_names) );
            ( "required_tool_candidate_names",
              `List
                (List.map
                   (fun name -> `String name)
                   acc.tool_surface.required_tool_candidate_names) );
            ( "missing_required_tool_names",
              `List
                (List.map
                   (fun name -> `String name)
                   acc.tool_surface.missing_required_tool_names) );
            ("config_root", `String acc.tool_surface.config_root);
          ])
      Keeper_runtime_manifest.Tool_surface_selected;
    let agent_ref : Agent_sdk.Agent.t option ref = ref None in
    let proof_ref : Masc_mcp_cdal_runtime.Cdal_proof.t option ref = ref None in
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
    let materialized_tool_names_ref : string list ref = ref [] in
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
       let require_tool_choice_support =
         should_require_provider_tool_choice_support
           ~initial_tool_requirement:initial_tool_surface.tool_requirement
           ~actionable_observation_requires_tool_support
       in
       let timeout_s =
         match oas_timeout_s with
         | Some value -> value
         | None -> Keeper_runtime_resolved.oas_call_timeout_sec ()
       in
       let per_provider_timeout_s =
         per_provider_timeout_for_turn
           ~meta
           ?oas_timeout_s
           ~oas_timeout_is_explicit
           ~timeout_s
           ()
       in
       (* OAS [stream_idle_timeout_s] bounds inter-line idle on HTTP streams
       (Provider_a/OpenAI/Provider_f/GLM/Ollama). The deadline resets after each
       successful line, so this is gap detection, not total run cap.

       CLI subprocess transports use a separate envelope:
       [cli_subprocess_idle_sec], wired into [cli_transport_overrides]
       below and forwarded to [Cli_common_subprocess.run_stream_lines]
       via [stdout_idle_timeout_s] (Provider_c CLI today; Claude Code / Provider_f
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
       let claude_mcp_config =
         (* #10049 Option C: auto-construct from the keeper bearer token +
            server host/port when env is unset. Gated behind
            MASC_AUTO_CONSTRUCT_CLAUDE_MCP (default true). The existing
            explicit-env path still wins, and operators can opt out by setting
            the flag false. *)
         Keeper_cli_mcp_config.effective_for_keeper
           ~base_path:config.base_path
           ~agent_name:meta.agent_name
           ~configured:keeper_oas_context.claude_mcp_config
       in
       (* Observability for issue #10049: warn only when the effective config
          is still missing after the auto-construction fallback. Otherwise the
          log incorrectly says the subprocess cannot see MCP even though the
          transport override is about to provide the generated config. *)
       let configured_model_labels =
         Keeper_model_labels.configured_model_labels_of_meta meta
       in
       let requires_runtime_mcp_header_sync =
         Cascade_runtime_candidate.labels_require_runtime_mcp_header_sync
           configured_model_labels
       in
       if
         Keeper_cli_mcp_config.missing_catalog_warning_required_for_effective
           ~requires_runtime_mcp_header_sync
           ~effective_claude_mcp_config:claude_mcp_config
       then
         Log.Keeper.warn
           "keeper %s (cascade=%s): cli-backed providers selected but \
            effective claude_mcp_config is None; MCP tool catalog will not \
            be visible to the subprocess (token missing, flag disabled, or \
           auto-construction failed)"
           meta.name
           cascade_name_string;
       let cli_transport_overrides =
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
       let turn_result =
         match pre_dispatch_checkpoint_error with
         | Some err -> Error err
         | None ->
           (match pre_dispatch_max_tokens_error with
            | Some err -> Error err
            | None ->
             (match !initial_tool_surface_blocker_ref with
            | Some err -> Error err
            | None ->
              let call_run_named ~initial_messages =
                let bridge_timeout_s =
                  Keeper_llm_bridge.with_hitl_approval_headroom timeout_s
                in
                Keeper_llm_bridge.run_with_timeout_and_fallback
                  ~timeout_s:bridge_timeout_s
                  (fun () ->
                          Keeper_turn_driver.run_named
                            ~cascade_name:cascade_name_string
                            ~base_path:config.base_path
                            ~keeper_name:meta.name
                    ?provider_filter
                    ~require_tool_choice_support
                    ~require_tool_support
                    ~goal:user_message
                    ~priority
                    ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                    ~system_prompt:turn_system_prompt
                    ~tools
                    ~compact_ratio:meta.compaction.ratio_gate
                    ~oas_auto_context_overflow_retry:true
                    ~initial_messages
                    ~hooks
                    ~context_reducer:reducer
                   ~summarizer:Keeper_summarizer.keeper_summarizer
                   ~memory
                   ~runtime_manifest_context
                   ~runtime_manifest_append:
                     (fun manifest ->
                        (match manifest.Keeper_runtime_manifest.event with
                         | Keeper_runtime_manifest.Provider_lane_resolved ->
                           (match manifest.Keeper_runtime_manifest.decision with
                            | `Assoc fields ->
                              (match List.assoc_opt "materialized_tool_names" fields with
                               | Some (`List names) ->
                                 materialized_tool_names_ref
                                   := List.filter_map
                                        (function
                                         | `String s -> Some s
                                         | _ -> None)
                                        names
                               | _ -> ())
                            | _ -> ())
                         | _ -> ());
                        Keeper_runtime_manifest.append_best_effort
                          ~site:"cascade_runtime"
                          config
                          manifest)
                   ~runtime_manifest_required_tool_names:
                     acc.tool_surface.required_tool_names
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
                      .required_tool_satisfaction_for_turn
                        ~required_tool_names:acc.tool_surface.required_tool_names
                        call)
                    ~max_turns
                    ~max_idle_turns
                    ?stream_idle_timeout_s
                    ~temperature
                    ~max_tokens
                    ?max_cost_usd
                    ?wait_timeout_sec:admission_wait_timeout_sec
                    ~accept:
                      Keeper_tool_disclosure.response_has_text_or_tool_progress
                    ?guardrails
                    ?on_event
                    ?on_yield
                    ?on_resume
                    ~agent_ref
                    ~proof_ref
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
              in
              (match
                 Keeper_agent_run_contract_retry.run_with_single_retry
                   ~keeper_name:meta.name
                   ~acc
                   ~has_current_task:
                     (Option.is_some (owned_active_task_id_for_meta ~config ~meta:acc.meta))
                   ~turn_affordances
                   ~history_messages
                   ~call_run_named
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
                 receipt_cascade_observation_ref := result.cascade_observation;
                 Keeper_agent_run_thinking_trajectory.persist_response_content
                   ~keeper_name:meta.name
                   ~trajectory_acc
                   result.response.content;
                 let tool_observation =
                   Keeper_agent_run_tool_observation.analyze
                     ~base_path:config.base_path
                     ~keeper_name:meta.name
                     ~requested_tool_names_seen:acc.requested_tool_names_seen
                     ~tool_usage_before
                     ~tool_calls:acc.tool_calls
                     result.response.content
                 in
                 let reported_tool_names =
                   tool_observation.reported_tool_names
                 in
                 reported_tool_names_ref := reported_tool_names;
                 let observed_tool_names =
                   tool_observation.observed_tool_names
                 in
                 observed_tool_names_ref := observed_tool_names;
                 (* RFC-0064: canonicalise observed tool names across all three
                    input surfaces (LLM-native public / MCP protocol /
                    already-internal) before the disclosure check. Without
                    this, the disclosure check flags every Execute/ReadFile call as
                    "unexpected" and nukes turns where the LLM only used the
                    alias names (≈18% of turns per #8778).

                    [canonical_tool_name_observed] is the observation
                    boundary — it emits exactly one
                    [masc_keeper_tool_call_total] sample per observed
                    name with bounded labels. Set-logic call sites
                    (required-tool canonicalisation, surface composition)
                    use the pure [canonical_tool_name] variant so a
                    single observed call does not produce multiple
                    counter samples (PR #14585 review #3). *)
                 let canonical_tool_names =
                   tool_observation.canonical_tool_names
                 in
                 canonical_tool_names_ref := canonical_tool_names;
                 let unexpected_tool_names =
                   tool_observation.unexpected_tool_names
                 in
                 unexpected_tool_names_ref := unexpected_tool_names;
                 (* Partial tolerance (#8471): when a turn mixes valid tool calls
          with unexpected ones (LLM hallucinating Claude Code built-ins
          like Execute/ReadFile/Skill outside the keeper surface), do not nuke
          the whole turn. OAS already returns tool_result="error" for the
          unknown calls so the LLM can recover on the next step. We still
          hard-fail when EVERY tool call is unexpected — that means the
          turn produced no valid work. See feedback memory
          feedback_tool-error-messages-teach-llm.md. *)
                 let valid_tool_calls_present =
                   tool_observation.valid_tool_calls_present
                 in
                 if valid_tool_calls_present then acc.keeper_surface_tool_used <- true;
                 if unexpected_tool_names <> [] && not valid_tool_calls_present
                 then (
                   acc.receipt_tool_contract_result <-
                     Keeper_execution_receipt.Contract_violated;
                   Error
                     (Keeper_agent_run_tool_surface_violation.to_sdk_error
                        ~keeper_name:meta.name
                        ~cascade_name:(Keeper_types.cascade_name_of_meta meta)
                        ~requested_tool_names_seen:acc.requested_tool_names_seen
                        ~unexpected_tool_names))
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
                       ~allowed_tool_names:acc.requested_tool_names_seen
                   in
                   actual_keeper_tool_names_ref := actual_keeper_tool_names;
                   let progress_keeper_tool_names =
                     progress_keeper_tool_names_for_contract
                       ~allowed_tool_names:acc.requested_tool_names_seen
                       ~actual_keeper_tool_names
                       ~tool_calls:acc.tool_calls
                   in
                   let no_progress_success_tool_names =
                     no_progress_success_tool_names_for_contract
                       ~allowed_tool_names:acc.requested_tool_names_seen
                       ~tool_calls:acc.tool_calls
                   in
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
                   let actionable_contract =
                     Keeper_agent_run_actionable_contract.analyze
                       ~world_observation
                       ~allowed_tool_names:all_tool_names
                       ~turn_affordances
                       ~progress_keeper_tool_names
                       ~no_progress_success_tool_names
                       ~claim_context_allowed:
                         (not had_owned_active_task_at_turn_start)
                   in
                   let actionable_signal_kind =
                     actionable_contract.actionable_signal_kind
                   in
                   let actionable_tool_contract_violation_reason =
                     actionable_contract.violation_reason
                   in
                   let tool_contract_status ()
                       : Keeper_execution_receipt.tool_contract_result =
                     Contract_helpers.observed_tool_contract_status
                       ~required_tool_names:acc.tool_surface.required_tool_names
                       ~missing_visible_required:
                         acc.tool_surface.missing_required_tool_names
                       ~had_owned_active_task_at_turn_start
                       ~actual_keeper_tool_names:progress_keeper_tool_names
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
                       let contract_status
                           : Keeper_execution_receipt.tool_contract_result =
                         Contract_helpers.passive_violation_contract_status
                           ~actual_keeper_tool_names
                           ~progress_keeper_tool_names
                           ~fallback:tool_contract_status
                       in
                       acc.receipt_tool_contract_result <- contract_status;
                       Keeper_agent_run_contract_violation_log.record_passive
                         ~keeper_name:meta.name
                         ~has_current_task:(keeper_has_owned_active_task ())
                         ~contract_status
                         ~actionable_signal_kind
                         ~turns:result.turns
                         ~actual_keeper_tool_names
                         ~reason;
                       Error
                         (Contract_helpers.completion_contract_violation_error reason)
                     | Ok (), None ->
                       acc.receipt_tool_contract_result <- tool_contract_status ();
                       Ok (`Provider_text text)
                     | Error reason, _ ->
                       let contract_status
                           : Keeper_execution_receipt.tool_contract_result =
                         Contract_helpers.text_only_violation_contract_status
                           ~actual_keeper_tool_names
                           ~fallback:tool_contract_status
                       in
                       acc.receipt_tool_contract_result <- contract_status;
                       Keeper_agent_run_contract_violation_log.record_text_only
                         ~keeper_name:meta.name
                         ~has_current_task:(keeper_has_owned_active_task ())
                         ~contract_status
                         ~effective_completion_contract
                         ~actionable_signal_kind
                         ~turns:result.turns
                         ~actual_keeper_tool_names
                         ~reason;
                       Error
                         (Contract_helpers.completion_contract_violation_error reason)
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
                      | Ok response_text ->
                        Keeper_agent_run_finalize_response.finalize
                          ~config ~meta ~generation ~manifest_keeper_turn_id
                          ~trace_id ~session ~append_manifest ~model
                          ~acc ~memory
                          ~actual_keeper_tool_names ~actual_keeper_tool_names_ref
                          ~result ~checkpoint_persistence_error ~proof_ref
                          ~post_turn_t0 ?provider_filter ~cascade_name_string
                          ~prompt_metrics ~ctx_composition ~usage
                          ~receipt_response_text_present_ref ~history_assistant_source
                          ~pre_dispatch_compacted:ctx.pre_dispatch_compacted
                          ~pre_dispatch_compaction_trigger:ctx.pre_dispatch_compaction_trigger
                          ~pre_dispatch_compaction_before_tokens:ctx.pre_dispatch_compaction_before_tokens
                          ~pre_dispatch_compaction_after_tokens:ctx.pre_dispatch_compaction_after_tokens
                          ~raw_response_text:response_text
                          ())))))
               in
       Keeper_agent_run_receipt.finalize
         ~config
         ~meta
         ~generation
         ~manifest_keeper_turn_id
         ~cascade_name
         ~keeper_visible_sandbox_root
         ~receipt_started_at
         ~runtime_manifest_context
         ~initial_tool_surface
         ~acc
         ~memory
         ~pre_dispatch_compacted
         ~pre_dispatch_compaction_trigger:ctx.pre_dispatch_compaction_trigger
         ~pre_dispatch_compaction_before_tokens:ctx.pre_dispatch_compaction_before_tokens
         ~pre_dispatch_compaction_after_tokens:ctx.pre_dispatch_compaction_after_tokens
         ~degraded_retry_applied
         ~degraded_retry_cascade
         ~fallback_reason
         ~cascade_rotation_attempts
         ~turn_result
         ~receipt_turn_count_ref
         ~receipt_model_used_ref
         ~receipt_stop_reason_ref
         ~receipt_cascade_observation_ref
         ~receipt_response_text_present_ref
         ~reported_tool_names_ref
         ~observed_tool_names_ref
         ~canonical_tool_names_ref
         ~unexpected_tool_names_ref
         ~actual_keeper_tool_names_ref
         ~materialized_tool_names_ref
         ())
