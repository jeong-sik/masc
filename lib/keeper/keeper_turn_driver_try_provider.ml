(** Keeper_turn_driver_try_provider — extracted [try_provider] closure.

    RFC-0051 PR-3a: closure-to-toplevel-fn conversion with explicit ctx record.
    The [try_provider] closure was defined inside [Keeper_turn_driver.run_named]
    and captured ~51 variables from the enclosing scope. This module makes
    that boundary explicit via a record, so the compiler verifies every
    dependency and the function body is independently testable.

    @since RFC-0051 PR-3a *)

open Result.Syntax

include Keeper_turn_driver_try_provider_setup

(** Run a single provider attempt within the cascade.

    This is the extracted body of the [try_provider] closure that was
    defined inside [Keeper_turn_driver.run_named]. The [ctx] record
    makes all captured dependencies explicit.

    @param ctx Explicit closure context (captures from [run_named]).
    @param resume_checkpoint Checkpoint from a previous failed provider.
    @param per_provider_timeout_s Per-provider wall-clock timeout.
    @param candidate The opaque runtime candidate to attempt.
    @return [(result, checkpoint_after, liveness_success_sample)] tuple. The
    sample is not recorded here; the caller records it only after the cascade
    accept predicate accepts the response. *)
let run_try_provider
      (ctx : try_provider_ctx)
      ?resume_checkpoint
      ?per_provider_timeout_s
      candidate
  =
  let config_result =
    match
      Cascade_runtime_candidate.resolve_tool_lane_for_oas_tools
        ?agent_name:(Cascade_oas_runner.keeper_agent_name_opt ctx.keeper_name)
        ~tool_requirement:
          (if ctx.require_tool_choice_support || ctx.require_tool_support
           then `Required
           else `Optional)
        ~tools:ctx.tools
        candidate
    with
    | Error _ as err -> err
    | Ok (effective_tools, runtime_mcp_policy) ->
      let runtime_mcp_policy =
        match runtime_mcp_policy, String.trim ctx.keeper_name with
        | Some policy, keeper_name when keeper_name <> "" ->
          Cascade_runtime_candidate.runtime_mcp_policy_for_agent
            ~agent_name:(Keeper_identity.keeper_agent_name ctx.keeper_name)
            candidate
            (Some policy)
        | _ -> runtime_mcp_policy
      in
      let requested_tool_names =
        List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name) ctx.tools
      in
      let materialized_tool_names =
        Keeper_turn_driver_helpers.materialized_tool_names_after_lane
          ~effective_tools
          ~runtime_mcp_policy
      in
      let missing_required_tool_names =
        Keeper_turn_driver_helpers.missing_required_tool_names_after_lane
          ~required_tool_names:ctx.runtime_manifest_required_tool_names
          ~effective_tools
          ~runtime_mcp_policy
      in
      let resolved_lane =
        Keeper_turn_driver_helpers.resolved_tool_lane_label ~effective_tools
          ~runtime_mcp_policy
      in
      let runtime_mcp_external_tools =
        effective_tools = [] && Option.is_some runtime_mcp_policy
      in
      let hooks =
        wrap_runtime_mcp_external_tool_hooks
          ~runtime_mcp_external_tools
          ctx.hooks
      in
      emit_runtime_manifest ctx
        ~status:(if missing_required_tool_names = [] then "resolved" else "error")
        ~decision:
          (`Assoc
            [
              ( "requested_tool_names",
                `List (List.map (fun name -> `String name) requested_tool_names) );
              ( "required_tool_names",
                `List
                  (List.map
                     (fun name -> `String name)
                     ctx.runtime_manifest_required_tool_names) );
              ( "materialized_tool_names",
                `List
                  (List.map (fun name -> `String name) materialized_tool_names) );
              ( "missing_required_tool_names_after_lane",
                `List
                  (List.map
                     (fun name -> `String name)
                     missing_required_tool_names) );
              ("resolved_lane", `String resolved_lane);
              ("effective_tool_count", `Int (List.length effective_tools));
              ("runtime_mcp_policy_present", `Bool (Option.is_some runtime_mcp_policy));
              ( "tool_requirement",
                `String
                  (if ctx.require_tool_choice_support || ctx.require_tool_support
                   then "required"
                   else "optional") );
            ])
        Keeper_runtime_manifest.Provider_lane_resolved;
      if missing_required_tool_names <> [] then
        Error
          (Keeper_turn_driver_helpers.required_tool_lane_unavailable_error
             ~lane:resolved_lane
             ~missing_required_tools:missing_required_tool_names
             ~materialized_tools:materialized_tool_names)
      else
        Ok
          { (Cascade_runtime_candidate.default_config
               ~name:ctx.name
               ~system_prompt:ctx.system_prompt
               ~tools:effective_tools
               candidate)
            with
            priority = ctx.priority
          ; max_turns = ctx.max_turns
          ; max_tokens = ctx.max_tokens
          ; max_input_tokens = ctx.max_input_tokens
          ; max_cost_usd = ctx.max_cost_usd
          ; stream_idle_timeout_s =
              (match per_provider_timeout_s with
               | Some _ as timeout_s -> timeout_s
               | None ->
                 Some
                   (Option.value
                      ~default:
                        Env_config_keeper.KeeperKeepalive.stream_idle_timeout_sec
                      ctx.stream_idle_timeout_s))
          ; max_execution_time_s =
              max_execution_time_for_attempt ?per_provider_timeout_s ()
          ; body_timeout_s =
              (* SSOT: Keeper_runtime_resolved.body_timeout_override_sec
                 (driven by MASC_KEEPER_BODY_TIMEOUT_SEC). When unset
                 (default), fall back to the per-attempt
                 max_execution_time so this wire matches the PR #16071
                 baseline. When set, the body-callback wall-clock fires
                 before the turn cap, surfacing Retry.Timeout so cascade
                 falls forward at the attempt boundary. *)
              (match Keeper_runtime_resolved.body_timeout_override_sec () with
               | Some _ as s -> s
               | None -> max_execution_time_for_attempt ?per_provider_timeout_s ())
          ; temperature = ctx.temperature
          ; max_idle_turns = ctx.max_idle_turns
          ; guardrails = ctx.guardrails
          ; hooks
          ; context_reducer = ctx.context_reducer
          ; memory = ctx.memory
          ; tool_retry_policy = ctx.tool_retry_policy
          ; required_tool_satisfaction = ctx.required_tool_satisfaction
          ; description =
              Some (Printf.sprintf "cascade:%s/runtime" ctx.cascade_name)
          ; transport = ctx.transport_resolved
          ; allowed_paths = ctx.allowed_paths
          ; checkpoint_sidecar = ctx.checkpoint_sidecar
          ; session_id = ctx.session_id
          ; cache_system_prompt = ctx.cache_system_prompt
          ; compact_ratio = ctx.compact_ratio
          ; oas_auto_context_overflow_retry = ctx.oas_auto_context_overflow_retry
          ; contract = ctx.contract
          ; checkpoint_dir = ctx.checkpoint_dir
          ; context_injector = ctx.context_injector
          ; context = ctx.context
          ; slot_id = ctx.slot_id
          ; enable_thinking = ctx.enable_thinking
          ; event_bus = ctx.event_bus
          ; approval = ctx.approval
          ; exit_condition = ctx.exit_condition
          ; exit_condition_result = ctx.exit_condition_result
          ; summarizer = ctx.summarizer
          ; initial_messages = ctx.initial_messages
          ; raw_trace = ctx.raw_trace
          ; yield_on_tool = ctx.yield_on_tool
          ; runtime_mcp_policy
          ; cli_transport_overrides = ctx.cli_transport_overrides
          }
  in
  let local_agent_ref : Agent_sdk.Agent.t option ref = ref None in
  match config_result with
  | Error err -> Error err, None, None
  | Ok config ->
    let liveness_mode = Cascade_attempt_liveness_config.current_mode () in
    (* MASC stores one neutral runtime-lane budget; concrete provider/model
       identities remain on the OAS side.  Prometheus receives only the public,
       bounded provider bucket for TTFT/inter-chunk grouping. *)
    let candidate_key = Cascade_attempt_liveness_config.runtime_candidate_key in
    let provider_label = Cascade_runtime_candidate.provider_label candidate in
    let liveness_observer_opt =
      match liveness_mode with
      | Cascade_attempt_liveness_config.Off ->
        (* RFC-0095 Phase 0 diagnostic trace — capture Off-mode turns. Combined with
           the existing Observe/Enforce-branch log below, this gives full visibility
           into whether the streaming master switch is the gating factor for
           openai_compat candidates. Removed at Phase 0 closeout. *)
        Log.Misc.debug
          "rfc0095-trace: liveness_mode=Off observer disabled cascade=%s provider=%s \
           candidate=%s"
          ctx.cascade_name
          provider_label
          candidate_key;
        None
      | Cascade_attempt_liveness_config.Observe | Cascade_attempt_liveness_config.Enforce
        ->
        let resolved_budget =
          Cascade_attempt_liveness_config.budget_for_candidate ~candidate_key
        in
        Log.Misc.debug
          "cascade_attempt_liveness: candidate=%s provider=%s budget_source=%s ttft=%.1fs \
           inter_chunk=%.1fs wall=%.1fs"
          candidate_key
          provider_label
          (Cascade_attempt_liveness_config.budget_source_label
             resolved_budget.source)
          resolved_budget.budget.Cascade_attempt_liveness.ttft_max
          resolved_budget.budget.Cascade_attempt_liveness.inter_chunk_max
          resolved_budget.budget.Cascade_attempt_liveness.attempt_wall_max;
        let obs =
          Cascade_attempt_liveness_observer.create
            ~mode:liveness_mode
            ~budget:resolved_budget.budget
            ~cascade_label:ctx.cascade_name
            ~provider_label
            ~external_wait:(fun () ->
              Keeper_approval_queue.has_pending_for_keeper
                ~keeper_name:ctx.keeper_name)
            ~candidate_key
            ~started_at:(Time_compat.now ())
            ()
        in
        Some obs
    in
    let finalize_liveness () =
      match liveness_observer_opt with
      | None -> ()
      | Some obs -> Cascade_attempt_liveness_observer.finalize obs
    in
    let liveness_success_sample () =
      match liveness_observer_opt with
      | None -> None
      | Some obs ->
        Cascade_attempt_liveness_observer.success_sample_for_candidate obs
    in
    let liveness_timeout_error failure =
      let kind = Cascade_attempt_liveness.failure_kind_label failure in
      Agent_sdk.Error.Api
        (Timeout
           { message =
               Printf.sprintf
                 "Cascade attempt liveness guard killed runtime lane %s: %s"
                 ctx.cascade_name
                 kind
           })
    in
    let with_liveness_attempt f =
      let stop_liveness_tick () =
        match liveness_observer_opt with
        | None -> ()
        | Some obs -> Cascade_attempt_liveness_observer.stop_tick_fiber obs
      in
      let run_attempt () =
        try
          Eio.Switch.run (fun attempt_sw ->
            (match liveness_observer_opt with
             | Some obs ->
               Cascade_attempt_liveness_observer.register_attempt_switch
                 obs
                 ~sw:attempt_sw
             | None -> ());
            (match liveness_observer_opt, Eio_context.get_clock_opt () with
             | Some obs, Some clock ->
               Cascade_attempt_liveness_observer.start_tick_fiber
                 obs
                 ~sw:attempt_sw
                 ~clock
             | Some _, None -> ()
             | None, _ -> ());
            let liveness_on_event =
              match liveness_observer_opt with
              | None -> ctx.on_event
              | Some obs ->
                Cascade_attempt_liveness_observer.wrap_on_event obs ctx.on_event
            in
            match f ~attempt_sw ~liveness_on_event with
            | result ->
              stop_liveness_tick ();
              result
            | exception exn ->
              let bt = Printexc.get_raw_backtrace () in
              stop_liveness_tick ();
              Printexc.raise_with_backtrace exn bt)
        with
        | Cascade_attempt_liveness_observer.Liveness_kill failure ->
          Error (liveness_timeout_error failure)
        | Eio.Cancel.Cancelled _ as e -> raise e
      in
      match run_attempt () with
      | result ->
        finalize_liveness ();
        result
      | exception exn ->
        let bt = Printexc.get_raw_backtrace () in
        finalize_liveness ();
        Printexc.raise_with_backtrace exn bt
    in
    (match
       Cascade_config_builder.with_cli_preflight
         ~scope:(Printf.sprintf "cascade:%s/runtime" ctx.cascade_name)
         ~config
         ~goal:ctx.goal
         (fun () ->
            let result =
              with_liveness_attempt (fun ~attempt_sw ~liveness_on_event ->
                let effective_checkpoint =
                  match resume_checkpoint with
                  | Some _ -> resume_checkpoint
                  | None -> ctx.oas_checkpoint
                in
                let run_fn () =
                  Eio_guard.check_if_ready ();
                  Cascade_runner.run
                    ~sw:attempt_sw
                    ~net:ctx.net
                    ~config
                    ?oas_checkpoint:effective_checkpoint
                    ?on_event:liveness_on_event
                    ?on_yield:ctx.on_yield
                    ?on_resume:ctx.on_resume
                    ~agent_ref:local_agent_ref
                    ?proof_ref:ctx.proof_ref
                    ?contract:ctx.contract
                    ctx.goal
                in
                let outer_wall_for_provider =
                  Cascade_attempt_liveness_config.outer_wall_for_attempt
                    ~mode:liveness_mode
                    ~observer_attached:(Option.is_some liveness_observer_opt)
                    ~per_provider_timeout_s
                    ~candidate_key
                in
                match outer_wall_for_provider with
                | None -> run_fn ()
                | Some t ->
                  let clock_opt =
                    match Masc_eio_env.get_opt () with
                    | Some env ->
                      (match env.clock with
                       | Some _ as clock_opt -> clock_opt
                       | None -> Eio_context.get_clock_opt ())
                    | None -> Eio_context.get_clock_opt ()
                  in
                  (match clock_opt with
                   | Some clock ->
                     (try Eio.Time.with_timeout_exn clock t run_fn with
                      | Eio.Time.Timeout ->
                        Log.Misc.info
                          "[cascade-fallback] cascade %s: runtime lane per-provider \
                           timeout after %.1fs, falling back"
                          ctx.cascade_name
                          t;
                        Error
                          (Agent_sdk.Error.Api
                             (Timeout
                                { message =
                                    Printf.sprintf "Per-provider timeout after %.1fs" t
                                })))
                   | None -> run_fn ()))
            in
            Ok result)
     with
     | Error err ->
       finalize_liveness ();
       Error err, None, None
     | Ok result ->
       finalize_liveness ();
       let liveness_success_sample = liveness_success_sample () in
       let result =
         Result.map_error
           (Cascade_runtime_candidate.enrich_sdk_error
              ~cascade_name:ctx.error_cascade_name
              candidate)
           result
       in
       let checkpoint_after =
         Keeper_turn_driver_helpers.checkpoint_after_attempt
           ?agent_ref:ctx.agent_ref
           !local_agent_ref
       in
       result, checkpoint_after, liveness_success_sample)
;;

module For_testing = struct
  let sanitize_runtime_mcp_external_tool_choice =
    sanitize_runtime_mcp_external_tool_choice
end
