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
  ; session_id : string option
  ; system_prompt : string
  ; tools : Agent_sdk.Tool.t list
  ; initial_messages : Agent_sdk.Types.message list
  ; model_input_projection :
      (Agent_sdk.Types.message list -> Agent_sdk.Types.message list) option
  ; stream_idle_timeout_s : float option
  ; body_timeout_s : float option
  ; temperature : float option
  ; accept : Agent_sdk_response.api_response -> bool
  ; hooks : Agent_sdk.Hooks.hooks option
  ; raw_trace : Agent_sdk.Raw_trace.t option
  ; trace_link : (string * string) option
  ; (* Transport *)
    transport_resolved : Masc_grpc_transport.t
  ; (* Session / checkpoint *)
    checkpoint_sidecar : Yojson.Safe.t option
  ; cache_system_prompt : bool
  ; yield_on_tool : bool
  ; checkpoint_sink : Agent_sdk.Agent.checkpoint_sink option
  ; checkpoint_stage_observed : bool Atomic.t
  ; context_injector : Agent_sdk.Hooks.context_injector option
  ; context : Agent_sdk.Context.t option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; exit_condition : (int -> bool) option
  ; exit_condition_result : (int -> Runtime_agent.stop_reason * string option) option
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

let accept_rejected_error ~runtime_id ~(response : Agent_sdk_response.api_response) =
  let rejection =
    Keeper_tool_response.accept_rejection_of_response ~runtime_id response
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
         reason = rejection.reason;
       })

let apply_accept
      ~runtime_id
      ~accept
      (run_result : Runtime_agent.run_result)
  =
  match run_result.stop_reason with
  | Runtime_agent.InputRequired _
  | Runtime_agent.TurnLimitObserved _
  | Runtime_agent.ExecutionTimeoutObserved _
  | Runtime_agent.ExecutionIdleTimeoutObserved _
  | Runtime_agent.Yielded_to_chat_waiting _
  | Runtime_agent.Yielded_to_durable_stimulus _ ->
    (* These are typed host-control terminals, not model deliverables. Running
       the normal response accept predicate over their question/blank carrier
       would turn them into [Accept_rejected] and incorrectly rotate providers,
       discarding typed control/observation evidence. Execution-limit
       observations never become a MASC acceptance gate. *)
    Ok run_result
  | Runtime_agent.Completed ->
    if accept run_result.response then Ok run_result
    else
      Error
        (accept_rejected_error
           ~runtime_id
           ~response:run_result.response)

(** Run a single provider attempt within the runtime.

    This is the extracted body of the [try_provider] closure that was
    defined inside [Keeper_turn_driver.run_named]. The [ctx] record
    makes all captured dependencies explicit.

    @param ctx Explicit closure context (captures from [run_named]).
    @param candidate The opaque runtime candidate to attempt.
    @return [(result, checkpoint_after, liveness_success_sample)] tuple. The
    sample is not recorded here; the caller records it only after the runtime
    accept predicate accepts the response. *)
let observe_checkpoint_stage observed (_ : Agent_sdk.Agent.checkpoint_stage) =
  Atomic.set observed true
;;

let same_run_retry_allowed observed = not (Atomic.get observed)

let run_try_provider
      (ctx : try_provider_ctx)
      ?enable_thinking_override
      candidate
  =
  (* [enable_thinking_override] lets the caller re-issue the SAME candidate with a
     different thinking policy without mutating [ctx]. RFC-0271 §4.1 uses it for the
     [Retry_no_thinking] recovery arm: a [Thinking_only_no_progress] rejection is
     retried once with thinking forced off before rerouting to the next candidate. *)
  let resolved_lane =
    match ctx.tools with
    | [] -> "none"
    | _ :: _ -> "inline"
  in
  emit_runtime_manifest ctx
    ~status:"resolved"
    ~decision:(`Assoc [ "resolved_lane", `String resolved_lane ])
    Keeper_runtime_manifest.Provider_lane_resolved;
  let checkpoint_sink (snapshot : Agent_sdk.Agent.checkpoint_snapshot) =
    observe_checkpoint_stage ctx.checkpoint_stage_observed snapshot.stage;
    match ctx.checkpoint_sink with
    | Some sink -> sink snapshot
    | None -> Ok ()
  in
  let config_result =
    let base_config =
      Runtime_candidate.default_config
        ~name:ctx.name
        ~system_prompt:ctx.system_prompt
        ~tools:ctx.tools
        candidate
    in
    (* Runtime/model configuration is authoritative; the run-level value only
       fills an omitted provider temperature. *)
    let temperature =
      match base_config.temperature with
      | Some _ as configured -> configured
      | None -> ctx.temperature
    in
    Ok
      { base_config with
        stream_idle_timeout_s = ctx.stream_idle_timeout_s
          ; body_timeout_s = ctx.body_timeout_s
          ; temperature
          ; hooks = ctx.hooks
          ; description =
              Some (Printf.sprintf "runtime:%s/runtime" ctx.runtime_id)
          ; transport = ctx.transport_resolved
          ; checkpoint_sidecar = ctx.checkpoint_sidecar
          ; session_id = ctx.session_id
          ; cache_system_prompt = ctx.cache_system_prompt
          ; checkpoint_sink = Some checkpoint_sink
          ; context_injector = ctx.context_injector
          ; context = ctx.context
          ; enable_thinking =
              (match enable_thinking_override with
               | Some v -> Some v
               | None -> ctx.enable_thinking)
          ; preserve_thinking = ctx.preserve_thinking
          ; event_bus = ctx.event_bus
          ; exit_condition = ctx.exit_condition
          ; exit_condition_result = ctx.exit_condition_result
          ; initial_messages = ctx.initial_messages
          ; model_input_projection = ctx.model_input_projection
          ; raw_trace = ctx.raw_trace
          ; trace_link = ctx.trace_link
          ; yield_on_tool = ctx.yield_on_tool
          }
  in
  let local_agent_ref : Agent_sdk.Agent.t option ref = ref None in
  match config_result with
  | Error err -> Error err, None, None
  | Ok config ->
    (* Explicit stream stall detection is handled by OAS's
       [stream_idle_timeout_s]; [None] deliberately leaves it disabled.
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
        let run_fn () =
          Eio_guard.check_if_ready ();
          match ctx.goal_blocks with
          | Some blocks ->
              Runtime_agent.run_blocks
                ~sw:attempt_sw
                ~net:ctx.net
                ~config
                ?oas_checkpoint:ctx.oas_checkpoint
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
                ?oas_checkpoint:ctx.oas_checkpoint
                ?on_event:ctx.on_event
                ?on_yield:ctx.on_yield
                ?on_resume:ctx.on_resume
                ~agent_ref:local_agent_ref
                ctx.goal
        in
        run_fn ())
    in
    let result =
      match result with
      | Ok run_result ->
        apply_accept
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
  let apply_accept = apply_accept
end
