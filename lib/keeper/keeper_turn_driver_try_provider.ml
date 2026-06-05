(** Keeper_turn_driver_try_provider — extracted [try_provider] closure.

    RFC-0051 PR-3a: closure-to-toplevel-fn conversion with explicit ctx record.
    The [try_provider] closure was defined inside [Keeper_turn_driver.run_named]
    and captured ~51 variables from the enclosing scope. This module makes
    that boundary explicit via a record, so the compiler verifies every
    dependency and the function body is independently testable.

    @since RFC-0051 PR-3a *)

open Result.Syntax

(** Explicit context record for the extracted [try_provider] function.

    Each field corresponds to a variable captured by the original closure.
    Fields are grouped by role: runtime identity, agent config, transport,
    session/checkpoint, Eio primitives, callbacks, and event bus. *)
type try_provider_ctx =
  { (* Runtime identity *)
    runtime_id : string
  ; error_runtime_id : string
  ; keeper_name : string
  ; name : string
  ; (* Agent config — fields passed through the runtime candidate boundary. *)
    goal : string
  ; priority : Llm_provider.Request_priority.t option
  ; session_id : string option
  ; system_prompt : string
  ; tools : Agent_sdk.Tool.t list
  ; initial_messages : Agent_sdk.Types.message list
  ; max_turns : int
  ; max_idle_turns : int
  ; stream_idle_timeout_s : float option
  ; temperature : float
  ; max_tokens : int
  ; max_input_tokens : int option
  ; max_cost_usd : float option
  ; guardrails : Agent_sdk.Guardrails.t option
  ; hooks : Agent_sdk.Hooks.hooks option
  ; context_reducer : Agent_sdk.Context_reducer.t option
  ; tool_retry_policy : Agent_sdk.Tool_retry_policy.t option
  ; raw_trace : Agent_sdk.Raw_trace.t option
  ; (* Transport *)
    transport_resolved : Masc_grpc_transport.t
  ; runtime_mcp_policy : Llm_provider.Llm_transport.runtime_mcp_policy option
  ; (* Session / checkpoint *)
    allowed_paths : string list
  ; checkpoint_sidecar : Yojson.Safe.t option
  ; cache_system_prompt : bool
  ; yield_on_tool : bool
  ; compact_ratio : float option
  ; oas_auto_context_overflow_retry : bool
  ; checkpoint_dir : string option
  ; context_injector : Agent_sdk.Hooks.context_injector option
  ; context : Agent_sdk.Context.t option
  ; slot_id : int option
  ; enable_thinking : bool option
  ; approval : Agent_sdk.Hooks.approval_callback option
  ; exit_condition : (int -> bool) option
  ; exit_condition_result : (int -> Runtime_agent.stop_reason * string option) option
  ; summarizer : (Agent_sdk.Types.message list -> string) option
  ; oas_checkpoint : Agent_sdk.Checkpoint.t option
  ; (* Eio concurrency *)
    sw : Eio.Switch.t
  ; net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  ; (* Callbacks *)
    on_event : (Agent_sdk.Types.sse_event -> unit) option
  ; on_yield : (unit -> unit) option
  ; on_resume : (unit -> unit) option
  ; agent_ref : Agent_sdk.Agent.t option ref option
  ; (* Event bus *)
    event_bus : Agent_sdk.Event_bus.t option
  ; runtime_manifest_context : Keeper_runtime_manifest.turn_context option
  ; runtime_manifest_append : (Keeper_runtime_manifest.t -> unit) option
  ; turn_start : Mtime.t
  ; seq_ref : int ref
  }

let emit_runtime_manifest
      (ctx : try_provider_ctx)
      ?status
      ?decision
      event
  =
  match ctx.runtime_manifest_context, ctx.runtime_manifest_append with
  | Some manifest_ctx, Some append ->
    let decision =
      (* RFC-0206: the runtime-engine manifest base fields are gone; the
         decision payload carries only its own fields now. *)
      match decision with
      | None -> Some (`Assoc [])
      | Some (`Assoc _) as d -> d
      | Some other -> Some (`Assoc [ ("decision", other) ])
    in
    ctx.seq_ref := !(ctx.seq_ref) + 1;
    let elapsed_ms =
      let ns =
        Mtime.Span.to_uint64_ns
          (Mtime.span ctx.turn_start (Mtime_clock.now ()))
      in
      Some (Int64.to_int (Int64.div ns 1_000_000L))
    in
    let decision =
      let decision =
        match decision with
        | Some value -> value
        | None -> `Assoc []
      in
      Some
        (Keeper_runtime_manifest.with_clock_refs
           ~clock_refs:
             (Keeper_runtime_manifest.clock_refs_for_context manifest_ctx ~event
                ?elapsed_ms ~logical_seq:!(ctx.seq_ref) ())
           decision)
    in
    Keeper_runtime_manifest.make_for_context manifest_ctx ~event
      ~runtime_id:ctx.runtime_id ?logical_seq:(Some !(ctx.seq_ref))
      ?status ?decision ()
    |> append
  | _ -> ()

let sanitize_runtime_mcp_external_tool_choice
      ~runtime_mcp_external_tools
      (params : Agent_sdk.Hooks.turn_params)
  =
  if not runtime_mcp_external_tools then params
  else
    match params.tool_choice with
    | Some (Agent_sdk.Types.Any | Agent_sdk.Types.Tool _) ->
      { params with tool_choice = Some Agent_sdk.Types.Auto }
    | Some (Agent_sdk.Types.Auto | Agent_sdk.Types.None_) | None -> params

let sanitize_runtime_mcp_external_tool_decision
      ~runtime_mcp_external_tools
      (decision : Agent_sdk.Hooks.hook_decision)
  =
  match decision with
  | Agent_sdk.Hooks.AdjustParams params ->
    Agent_sdk.Hooks.AdjustParams
      (sanitize_runtime_mcp_external_tool_choice
         ~runtime_mcp_external_tools
         params)
  | _ -> decision

let wrap_runtime_mcp_external_tool_hooks
      ~runtime_mcp_external_tools
      (hooks : Agent_sdk.Hooks.hooks option)
  =
  match hooks, runtime_mcp_external_tools with
  | None, _ | Some _, false -> hooks
  | Some hooks, true ->
    let before_turn_params =
      Option.map
        (fun hook event ->
           hook event
           |> sanitize_runtime_mcp_external_tool_decision
                ~runtime_mcp_external_tools:true)
        hooks.before_turn_params
    in
    Some { hooks with before_turn_params }

let max_execution_time_for_attempt ?per_provider_timeout_s () =
  (* Never forward per-provider timeouts to OAS [max_execution_time_s].
     That field is a cumulative wall-clock kill switch for one Agent.run /
     run_stream call; it cancels healthy active streams even while chunks are
     arriving. Provider-attempt liveness is progress-based instead:
     [stream_idle_timeout_s] catches inter-line stalls, the liveness observer
     catches no-first-token / inter-chunk gaps, and the keeper turn watchdog is
     the outer runaway guard. *)
  (match per_provider_timeout_s with
   | Some (_ : float) -> ()
   | None -> ());
  None

let stream_idle_timeout_for_attempt ~configured =
  Some
    (Option.value
       ~default:Env_config_keeper.KeeperKeepalive.stream_idle_timeout_sec
       configured)

let body_timeout_for_attempt ?per_provider_timeout_s () =
  match Keeper_runtime_resolved.body_timeout_override_sec () with
  | Some _ as s -> s
  | None -> max_execution_time_for_attempt ?per_provider_timeout_s ()

(** Run a single provider attempt within the runtime.

    This is the extracted body of the [try_provider] closure that was
    defined inside [Keeper_turn_driver.run_named]. The [ctx] record
    makes all captured dependencies explicit.

    @param ctx Explicit closure context (captures from [run_named]).
    @param resume_checkpoint Checkpoint from a previous failed provider.
    @param per_provider_timeout_s Per-provider wall-clock timeout.
    @param candidate The opaque runtime candidate to attempt.
    @return [(result, checkpoint_after, liveness_success_sample)] tuple. The
    sample is not recorded here; the caller records it only after the runtime
    accept predicate accepts the response. *)
let run_try_provider
      (ctx : try_provider_ctx)
      ?resume_checkpoint
      ?per_provider_timeout_s
      candidate
  =
  let config_result =
    match
      Runtime_candidate.resolve_tool_lane_for_oas_tools
        ?agent_name:(Runtime_oas_runner.keeper_agent_name_opt ctx.keeper_name)
        ~tools:ctx.tools
        candidate
    with
    | Error _ as err -> err
    | Ok (effective_tools, runtime_mcp_policy) ->
      let runtime_mcp_policy =
        match runtime_mcp_policy, String.trim ctx.keeper_name with
        | Some policy, keeper_name when keeper_name <> "" ->
          Runtime_candidate.runtime_mcp_policy_for_agent
            ~agent_name:(Keeper_identity.keeper_agent_name ctx.keeper_name)
            candidate
            (Some policy)
        | _ -> runtime_mcp_policy
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
        ~status:"resolved"
        ~decision:
          (`Assoc
            [
              ("resolved_lane", `String resolved_lane);
            ])
        Keeper_runtime_manifest.Provider_lane_resolved;
      Ok
        { (Runtime_candidate.default_config
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
              stream_idle_timeout_for_attempt ~configured:ctx.stream_idle_timeout_s
          ; max_execution_time_s =
              max_execution_time_for_attempt ?per_provider_timeout_s ()
          ; body_timeout_s =
              (* SSOT: Keeper_runtime_resolved.body_timeout_override_sec
                 (driven by MASC_KEEPER_BODY_TIMEOUT_SEC). When unset, do not
                 inherit [per_provider_timeout_s]: a cumulative body deadline
                 is another mid-stream killer for healthy reasoning bursts.
                 Stall detection is handled by [stream_idle_timeout_s]. *)
              body_timeout_for_attempt ?per_provider_timeout_s ()
          ; temperature = ctx.temperature
          ; max_idle_turns = ctx.max_idle_turns
          ; guardrails = ctx.guardrails
          ; hooks
          ; context_reducer = ctx.context_reducer
          ; tool_retry_policy = ctx.tool_retry_policy
          ; description =
              Some (Printf.sprintf "runtime:%s/runtime" ctx.runtime_id)
          ; transport = ctx.transport_resolved
          ; allowed_paths = ctx.allowed_paths
          ; checkpoint_sidecar = ctx.checkpoint_sidecar
          ; session_id = ctx.session_id
          ; cache_system_prompt = ctx.cache_system_prompt
          ; compact_ratio = ctx.compact_ratio
          ; oas_auto_context_overflow_retry = ctx.oas_auto_context_overflow_retry
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
          }
  in
  let local_agent_ref : Agent_sdk.Agent.t option ref = ref None in
  match config_result with
  | Error err -> Error err, None, None
  | Ok config ->
    let liveness_mode = Keeper_attempt_liveness_config.current_mode () in
    (* MASC stores one neutral runtime-lane budget; concrete provider/model
       identities remain on the OAS side.  Otel_metric_store receives only the public,
       bounded provider bucket for TTFT/inter-chunk grouping. *)
    let candidate_key = Keeper_attempt_liveness_config.runtime_candidate_key in
    let provider_label = Runtime_candidate.provider_label candidate in
    let liveness_observer_opt =
      match liveness_mode with
      | Keeper_attempt_liveness_config.Off ->
        (* RFC-0095 Phase 0 diagnostic trace — capture Off-mode turns. Combined with
           the existing Observe/Enforce-branch log below, this gives full visibility
           into whether the streaming master switch is the gating factor for
           openai_compat candidates. Removed at Phase 0 closeout. *)
        Log.Misc.debug
          "rfc0095-trace: liveness_mode=Off observer disabled runtime=%s provider=%s \
           candidate=%s"
          ctx.runtime_id
          provider_label
          candidate_key;
        None
      | Keeper_attempt_liveness_config.Observe | Keeper_attempt_liveness_config.Enforce
        ->
        let resolved_budget =
          Keeper_attempt_liveness_config.budget_for_candidate ~candidate_key
        in
        Log.Misc.debug
          "runtime_attempt_liveness: candidate=%s provider=%s budget_source=%s ttft=%.1fs \
           inter_chunk=%.1fs wall=%.1fs"
          candidate_key
          provider_label
          (Keeper_attempt_liveness_config.budget_source_label
             resolved_budget.source)
          resolved_budget.budget.Keeper_attempt_liveness.ttft_max
          resolved_budget.budget.Keeper_attempt_liveness.inter_chunk_max
          resolved_budget.budget.Keeper_attempt_liveness.attempt_wall_max;
        let obs =
          Keeper_attempt_liveness_observer.create
            ~mode:liveness_mode
            ~budget:resolved_budget.budget
            ~runtime_id:ctx.runtime_id
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
      | Some obs -> Keeper_attempt_liveness_observer.finalize obs
    in
    let liveness_success_sample () =
      match liveness_observer_opt with
      | None -> None
      | Some obs ->
        Keeper_attempt_liveness_observer.success_sample_for_candidate obs
    in
    let liveness_timeout_error failure =
      let kind = Keeper_attempt_liveness.failure_kind_label failure in
      Agent_sdk.Error.Api
        (Timeout
           { message =
               Printf.sprintf
                 "Runtime attempt liveness guard killed runtime lane %s: %s"
                 ctx.runtime_id
                 kind
           })
    in
    let with_liveness_attempt f =
      let stop_liveness_tick () =
        match liveness_observer_opt with
        | None -> ()
        | Some obs -> Keeper_attempt_liveness_observer.stop_tick_fiber obs
      in
      let run_attempt () =
        try
          Eio.Switch.run (fun attempt_sw ->
            (match liveness_observer_opt with
             | Some obs ->
               Keeper_attempt_liveness_observer.register_attempt_switch
                 obs
                 ~sw:attempt_sw
             | None -> ());
            (match liveness_observer_opt, Eio_context.get_clock_opt () with
             | Some obs, Some clock ->
               Keeper_attempt_liveness_observer.start_tick_fiber
                 obs
                 ~sw:attempt_sw
                 ~clock
             | Some _, None -> ()
             | None, _ -> ());
            let liveness_on_event =
              match liveness_observer_opt with
              | None -> ctx.on_event
              | Some obs ->
                Keeper_attempt_liveness_observer.wrap_on_event obs ctx.on_event
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
        | Keeper_attempt_liveness_observer.Liveness_kill failure ->
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
       (* RFC-0206: the runtime CLI-preflight wrapper is gone; run the single
          provider attempt directly. *)
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
                  Runtime_agent.run
                    ~sw:attempt_sw
                    ~net:ctx.net
                    ~config
                    ?oas_checkpoint:effective_checkpoint
                    ?on_event:liveness_on_event
                    ?on_yield:ctx.on_yield
                    ?on_resume:ctx.on_resume
                    ~agent_ref:local_agent_ref
                    ctx.goal
                in
                let outer_wall_for_provider =
                  Keeper_attempt_liveness_config.outer_wall_for_attempt
                    ~mode:liveness_mode
                    ~observer_attached:
                      (Option.is_some liveness_observer_opt
                       || Option.is_some ctx.on_event)
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
                          "[runtime-fallback] runtime %s: runtime lane per-provider \
                           timeout after %.1fs, falling back"
                          ctx.runtime_id
                          t;
                        Error
                          (Agent_sdk.Error.Api
                             (Timeout
                                { message =
                                    Printf.sprintf "Per-provider timeout after %.1fs" t
                                })))
                   | None -> run_fn ()))
            in
            Ok result) ()
     with
     | Error err ->
       finalize_liveness ();
       Error err, None, None
     | Ok result ->
       finalize_liveness ();
       let liveness_success_sample = liveness_success_sample () in
       let result =
         Result.map_error
           (Runtime_candidate.enrich_sdk_error
              ~runtime_id:ctx.error_runtime_id
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
  let max_execution_time_for_attempt = max_execution_time_for_attempt
  let stream_idle_timeout_for_attempt = stream_idle_timeout_for_attempt
  let sanitize_runtime_mcp_external_tool_choice =
    sanitize_runtime_mcp_external_tool_choice
end
