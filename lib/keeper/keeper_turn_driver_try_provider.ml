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
  ; base_path : string
  ; keeper_name : string
  ; name : string
  ; (* Agent config — fields passed through the runtime candidate boundary. *)
    goal : string
  ; goal_blocks : Agent_sdk.Types.content_block list option
  ; priority : Llm_provider.Request_priority.t option
  ; session_id : string option
  ; system_prompt : string
  ; tools : Agent_sdk.Tool.t list
  ; initial_messages : Agent_sdk.Types.message list
  ; max_turns : int
  ; max_idle_turns : int
  ; stream_idle_timeout_s : float option
  ; execution_idle_timeout_s : float option
  ; body_timeout_s : float option
  ; temperature : float
  ; max_tokens : int option
  ; accept : Agent_sdk_response.api_response -> bool
  ; guardrails : Agent_sdk.Guardrails.t option
  ; hooks : Agent_sdk.Hooks.hooks option
  ; context_reducer : Agent_sdk.Context_reducer.t option
  ; raw_trace : Agent_sdk.Raw_trace.t option
  ; trace_link : (string * string) option
  ; (* Transport *)
    transport_resolved : Masc_grpc_transport.t
  ; runtime_mcp_policy : Llm_provider.Llm_transport.runtime_mcp_policy option
  ; (* Session / checkpoint *)
    allowed_paths : string list
  ; checkpoint_sidecar : Yojson.Safe.t option
  ; cache_system_prompt : bool
  ; yield_on_tool : bool
  ; compact_ratio : float option
  ; context_window_tokens : int option
  ; oas_auto_context_overflow_retry : bool
  ; checkpoint_dir : string option
  ; context_injector : Agent_sdk.Hooks.context_injector option
  ; context : Agent_sdk.Context.t option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
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
  ; on_runtime_observation :
      (Runtime_observation.runtime_observation -> unit) option
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
     catches no-first-token / inter-chunk gaps, and tool/max-turn limits bound
     finite work. *)
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

type last_tool_progress_context =
  { tool_name : string
  ; tool_effect : Keeper_internal_error.tool_progress_effect
  ; any_mutating_tool : bool
  ; tool_effects_seen : Keeper_internal_error.tool_progress_effect list
  }

let last_tool_effect_to_string = Keeper_internal_error.tool_progress_effect_to_string

let classify_tool_effect ~tool_name ~input =
  if Keeper_tool_registry.is_strictly_read_only_with_input ~tool_name ~input
  then Keeper_internal_error.Tool_effect_read_only
  else Keeper_internal_error.Tool_effect_mutating
;;

let dedupe_tool_effects effects =
  effects
  |> List.fold_left
       (fun acc tool_effect ->
          if List.mem tool_effect acc then acc else tool_effect :: acc)
       []
  |> List.rev
;;

let tool_uses_of_messages (messages : Agent_sdk.Types.message list) =
  let tool_uses_in_message (msg : Agent_sdk.Types.message) acc =
    if msg.role <> Agent_sdk.Types.Assistant
    then acc
    else
      List.fold_left
        (fun acc block ->
          match Agent_sdk.Canonical_tool.tool_call_of_block block with
          | Some call ->
              (call.Agent_sdk.Canonical_tool.name, call.Agent_sdk.Canonical_tool.input)
              :: acc
          | None -> acc)
        acc
        msg.content
  in
  List.fold_left (fun acc msg -> tool_uses_in_message msg acc) [] messages
  |> List.rev
;;

let last_tool_progress_context_of_messages messages =
  match tool_uses_of_messages messages with
  | [] -> None
  | tool_uses ->
    let tool_effects =
      List.map
        (fun (tool_name, input) -> classify_tool_effect ~tool_name ~input)
        tool_uses
    in
    let last_tool_name, last_input =
      match List.rev tool_uses with
      | (tool_name, input) :: _ -> tool_name, input
      | [] -> "unknown", `Assoc []
    in
    let tool_name = last_tool_name in
    let tool_name = String.trim tool_name in
    let tool_name = if tool_name = "" then "unknown" else tool_name in
    let tool_effect = classify_tool_effect ~tool_name ~input:last_input in
    let any_mutating_tool =
      List.exists
        (function
          | Keeper_internal_error.Tool_effect_mutating -> true
          | Keeper_internal_error.Tool_effect_read_only -> false)
        tool_effects
    in
    Some
      {
        tool_name;
        tool_effect;
        any_mutating_tool;
        tool_effects_seen = dedupe_tool_effects tool_effects;
      }
;;

let rec drop_matching_prefix ~prefix messages =
  match prefix, messages with
  | [], rest -> rest
  | p :: ps, m :: ms when p = m -> drop_matching_prefix ~prefix:ps ms
  | _ :: _, _ -> messages
;;

let accept_rejection_context_of_run_result
      ?(initial_messages = [])
      (run_result : Runtime_agent.run_result)
  =
  match run_result.checkpoint with
  | None -> None
  | Some checkpoint ->
    checkpoint.Agent_sdk.Checkpoint.messages
    |> drop_matching_prefix ~prefix:initial_messages
    |> last_tool_progress_context_of_messages
;;

let format_last_tool_progress_context = function
  | None -> None
  | Some { tool_name; tool_effect; any_mutating_tool; tool_effects_seen } ->
    let effects_seen =
      tool_effects_seen
      |> List.map last_tool_effect_to_string
      |> String.concat ","
    in
    Some
      (Printf.sprintf
         "last_tool=%s; last_tool_effect=%s; any_mutating_tool=%b; \
          tool_effects_seen=%s"
         tool_name
         (last_tool_effect_to_string tool_effect)
         any_mutating_tool
         effects_seen)
;;

let accept_rejected_error ~last_tool_context ~runtime_id
    ~(response : Agent_sdk_response.api_response) =
  let rejection =
    Keeper_tool_response.accept_rejection_of_response ~runtime_id response
  in
  let progress_context = format_last_tool_progress_context last_tool_context in
  let rejection =
    match progress_context with
    | Some context when String.trim context <> "" ->
      { rejection with reason = rejection.reason ^ "; " ^ context }
    | Some _ | None -> rejection
  in
  let reason_kind =
    match rejection.kind with
    | Keeper_tool_response.No_usable_progress ->
      Some Keeper_internal_error.Accept_no_usable_progress
    | Keeper_tool_response.Predicate_rejected ->
      Some Keeper_internal_error.Accept_predicate_rejected
  in
  Keeper_internal_error.sdk_error_of_masc_internal_error
    (Keeper_internal_error.Accept_rejected
       {
         scope = runtime_id;
         model =
           Some
             (Boundary_redaction.to_string
                Boundary_redaction.runtime_model_label);
         reason_kind;
         response_shape =
           Option.map
             Keeper_internal_error.accept_response_shape_of_agent_sdk
             rejection.response_shape;
         (* RFC-0271 §4.5: preserve the provider's typed stop_reason so the
            classifier can tell a [MaxTokens] truncation from a clean [EndTurn]
            no-progress terminal. *)
         stop_reason = Some response.stop_reason;
         last_tool_effect =
           Option.map
             (fun context -> context.tool_effect)
             last_tool_context;
         any_mutating_tool =
           Option.map
             (fun context -> context.any_mutating_tool)
             last_tool_context;
         tool_effects_seen =
           (match last_tool_context with
            | Some context -> context.tool_effects_seen
            | None -> []);
         reason = rejection.reason;
       })

let apply_accept
      ?(initial_messages = [])
      ~runtime_id
      ~accept
      (run_result : Runtime_agent.run_result)
  =
  if accept run_result.response then Ok run_result
  else
    let last_tool_context =
      accept_rejection_context_of_run_result ~initial_messages run_result
    in
    Error
      (accept_rejected_error
         ~last_tool_context
         ~runtime_id
         ~response:run_result.response)

(** Run a single provider attempt within the runtime.

    This is the extracted body of the [try_provider] closure that was
    defined inside [Keeper_turn_driver.run_named]. The [ctx] record
    makes all captured dependencies explicit.

    @param ctx Explicit closure context (captures from [run_named]).
    @param resume_checkpoint Checkpoint from a previous failed provider.
    @param per_provider_timeout_s Legacy per-provider budget used for manifest
    diagnostics only. It is not applied as a cumulative timeout around
    [Runtime_agent.run] because that run may include active tool execution.
    @param candidate The opaque runtime candidate to attempt.
    @return [(result, checkpoint_after, liveness_success_sample)] tuple. The
    sample is not recorded here; the caller records it only after the runtime
    accept predicate accepts the response. *)
let run_try_provider
      (ctx : try_provider_ctx)
      ?resume_checkpoint
      ?per_provider_timeout_s
      ?enable_thinking_override
      candidate
  =
  (* [enable_thinking_override] lets the caller re-issue the SAME candidate with a
     different thinking policy without mutating [ctx]. RFC-0271 §4.1 uses it for the
     [Retry_no_thinking] recovery arm: a [Thinking_only_no_progress] rejection is
     retried once with thinking forced off before rerouting to the next candidate. *)
  let config_result =
    match
      Runtime_candidate.resolve_tool_lane_for_oas_tools
        ~base_path:ctx.base_path
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
            ~base_path:ctx.base_path
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
          ; max_tokens = ctx.max_tokens
          ; stream_idle_timeout_s =
              stream_idle_timeout_for_attempt ~configured:ctx.stream_idle_timeout_s
          ; max_execution_time_s =
              max_execution_time_for_attempt ?per_provider_timeout_s ()
          ; execution_idle_timeout_s =
              (* Keeper/provider attempts must not forward Agent.run idle
                 timeout until active tool execution is excluded from OAS idle
                 accounting. *)
              (let _ = ctx.execution_idle_timeout_s in
               None)
          ; body_timeout_s = ctx.body_timeout_s
          ; temperature = ctx.temperature
          ; max_turns = ctx.max_turns
          ; max_idle_turns = ctx.max_idle_turns
          ; guardrails = ctx.guardrails
          ; hooks
          ; context_reducer = ctx.context_reducer
          ; description =
              Some (Printf.sprintf "runtime:%s/runtime" ctx.runtime_id)
          ; transport = ctx.transport_resolved
          ; allowed_paths = ctx.allowed_paths
          ; checkpoint_sidecar = ctx.checkpoint_sidecar
          ; session_id = ctx.session_id
          ; cache_system_prompt = ctx.cache_system_prompt
          ; compact_ratio = ctx.compact_ratio
          ; context_window_tokens = ctx.context_window_tokens
          ; oas_auto_context_overflow_retry = ctx.oas_auto_context_overflow_retry
          ; checkpoint_dir = ctx.checkpoint_dir
          ; context_injector = ctx.context_injector
          ; context = ctx.context
          ; enable_thinking =
              (match enable_thinking_override with
               | Some v -> Some v
               | None -> ctx.enable_thinking)
          ; preserve_thinking = ctx.preserve_thinking
          ; event_bus = ctx.event_bus
          ; approval = ctx.approval
          ; exit_condition = ctx.exit_condition
          ; exit_condition_result = ctx.exit_condition_result
          ; summarizer = ctx.summarizer
          ; initial_messages = ctx.initial_messages
          ; raw_trace = ctx.raw_trace
          ; trace_link = ctx.trace_link
          ; yield_on_tool = ctx.yield_on_tool
          ; runtime_mcp_policy
          }
  in
  let local_agent_ref : Agent_sdk.Agent.t option ref = ref None in
  match config_result with
  | Error err -> Error err, None, None
  | Ok config ->
    (* Stream stall detection is handled by OAS's stream_idle_timeout_s.
       No separate liveness FSM — provider stall is an OAS-level concern.
       No per-lane capacity gate — provider load is managed by operator
       adjusting keeper count. *)
    let run_started_at =
      Unix.gettimeofday ()
      (* NDT-OK: provider-attempt latency telemetry only; dispatch/control
         decisions do not branch on this timestamp. *)
    in
    let result =
      Eio.Switch.run (fun attempt_sw ->
        let effective_checkpoint =
          match resume_checkpoint with
          | Some _ -> resume_checkpoint
          | None -> ctx.oas_checkpoint
        in
        let run_fn () =
          Eio_guard.check_if_ready ();
          match ctx.goal_blocks with
          | Some blocks ->
              Runtime_agent.run_blocks
                ~sw:attempt_sw
                ~net:ctx.net
                ~config
                ?oas_checkpoint:effective_checkpoint
                ?on_event:ctx.on_event
                ?on_yield:ctx.on_yield
                ?on_resume:ctx.on_resume
                ~agent_ref:local_agent_ref
                ~goal_detail:ctx.goal
                blocks
          | None ->
              Runtime_agent.run
                ~sw:attempt_sw
                ~net:ctx.net
                ~config
                ?oas_checkpoint:effective_checkpoint
                ?on_event:ctx.on_event
                ?on_yield:ctx.on_yield
                ?on_resume:ctx.on_resume
                ~agent_ref:local_agent_ref
                ctx.goal
        in
        (* Do not wrap [Runtime_agent.run] in a MASC wall-clock timeout here.
           OAS provider stream/body timeouts and tool-local subprocess budgets
           are the safe liveness boundaries. A cumulative wrapper at this layer
           cannot distinguish provider silence from active tool execution. *)
        (match per_provider_timeout_s with
         | Some (_ : float) -> ()
         | None -> ());
        run_fn ())
    in
    let result =
      (* Restore typed provider-context enrichment (auth-env / not-found hints).
         [Runtime_candidate] lives below [lib/keeper] and cannot reach this
         keeper-level helper, so the enrichment is applied here at the consumer
         with the candidate's provider config. *)
      Result.map_error
        (Keeper_runtime_attempt.enrich_sdk_error
           ~runtime_id:ctx.error_runtime_id
           ~provider_cfg:(Runtime_candidate.provider_cfg candidate))
        result
    in
    let result =
      match result with
      | Ok run_result ->
        apply_accept
          ~initial_messages:ctx.initial_messages
          ~runtime_id:ctx.error_runtime_id
          ~accept:ctx.accept
          run_result
      | Error _ as err -> err
    in
    (match ctx.on_runtime_observation, result with
     | Some emit, Ok run_result ->
       Option.iter emit run_result.Runtime_agent.runtime_observation
     | Some emit, Error err ->
       let total_duration_ms =
         (Unix.gettimeofday ()
          (* NDT-OK: closes the provider-attempt latency telemetry sample above. *)
          -. run_started_at)
         *. 1000.0
       in
       Runtime_agent.runtime_observation_for_terminal_config
         ~total_duration_ms
         ~error:(Agent_sdk.Error.to_string err)
         config
       |> emit
     | None, _ -> ());
    let checkpoint_after =
      Keeper_turn_driver_helpers.checkpoint_after_attempt
        ?agent_ref:ctx.agent_ref
        !local_agent_ref
    in
    result, checkpoint_after, None
;;

module For_testing = struct
  let max_execution_time_for_attempt = max_execution_time_for_attempt
  let stream_idle_timeout_for_attempt = stream_idle_timeout_for_attempt
  let sanitize_runtime_mcp_external_tool_choice =
    sanitize_runtime_mcp_external_tool_choice
  let apply_accept = apply_accept
  let last_tool_progress_context_of_messages = last_tool_progress_context_of_messages
  let format_last_tool_progress_context = format_last_tool_progress_context
end
