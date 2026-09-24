(* Total typed failure routing. See keeper_runtime_failure_route.mli. *)

type retry_class =
  | Rate_limited
  | Hard_quota
  | Provider_capacity
  | Empty_completion of { stop_reason : Llm_provider.Types.stop_reason }
  | Server_error
  | Network_transient
  | Provider_timeout

type rotate_class =
  | Auth_failed
  | Model_unavailable
  | Resumable_cli_session
  | Candidates_filtered
  | Runtime_exhausted
  | No_progress_empty
  | No_progress_thinking_only
  | No_progress_truncated
  | Refusal_body_not_received
  | Generation_repeated
  | Attempt_rejected
  | Provider_reported_failure
  | Request_refused
  | Provider_wire_defect
  | Server_error_not_transient

type fence_disposition =
  | Fenced_effect_attempted
  | Fenced_observation_unavailable

type terminal_class =
  | Deterministic_request
  | Context_overflow
  | Session_claim_refused
  | Transcript_refused
  | Contract_violation
  | Protocol_error
  | Config_mismatch
  | Provider_integration
  | Terminal_effect_dependency_unavailable
  | Terminal_effect_policy_rejection
  | Terminal_effect_runtime_failure
  | Terminal_effect_workflow_rejection
  | Terminal_effect_operator_cancelled
  | Provider_attempt_effect_fenced of fence_disposition
  | Tool_correction_lost of fence_disposition
  | Internal_opaque

type failure_provenance =
  | Agent_core_api_error
  | Agent_core_provider_error
  | Agent_core_agent_error
  | Agent_core_mcp_error
  | Agent_core_config_error
  | Agent_core_serialization_error
  | Agent_core_io_error
  | Agent_core_orchestration_error
  | Agent_core_internal_error
  | Masc_internal_error
  | Completion_contract

type error_boundary =
  | Masc_execution
  | Agent_core_execution

type route =
  | Retry_after_observed of
      { retry_class : retry_class
      ; retry_after : float option
      }
  | Rotate_now of { rotate : rotate_class }
  | Exhausted_visible_alive of
      { terminal : terminal_class
      ; provenance : failure_provenance
      ; detail : string
      }

let core_error_is_hard_quota (err : Agent_core.Error.t) =
  match err with
  | Agent_core.Error.Api (Llm_provider.Retry.PaymentRequired _)
  | Agent_core.Error.Provider (Llm_provider.Error.HardQuota _) ->
    true
  | Agent_core.Error.Api _
  | Agent_core.Error.Provider _
  | Agent_core.Error.Agent _
  | Agent_core.Error.Mcp _
  | Agent_core.Error.Config _
  | Agent_core.Error.Serialization _
  | Agent_core.Error.Io _
  | Agent_core.Error.Orchestration _
  | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried _ ->
    false
;;

let observe_retry ?retry_after retry_class =
  Retry_after_observed { retry_class; retry_after }

let rotate rotate_class = Rotate_now { rotate = rotate_class }

let failure_detail err =
  Keeper_internal_error.cap_blocker_detail (Agent_core.Error.to_string err)

let exhaust ~err ~provenance terminal_class =
  Exhausted_visible_alive
    { terminal = terminal_class; provenance; detail = failure_detail err }

let route_of_masc_internal ~err (internal : Keeper_internal_error.masc_internal_error) =
  let exhaust_failure = exhaust ~err ~provenance:Masc_internal_error in
  match internal with
  | Keeper_internal_error.Resumable_cli_session _ -> rotate Resumable_cli_session
  | Keeper_internal_error.Runtime_exhausted { reason; _ } ->
    (match reason with
     | Keeper_internal_error.Candidates_filtered_after_cycles ->
       rotate Candidates_filtered
     | Keeper_internal_error.Connection_refused
     | Keeper_internal_error.Dns_failure ->
       observe_retry Network_transient
     | Keeper_internal_error.No_providers_available
     | Keeper_internal_error.All_providers_failed
     | Keeper_internal_error.Session_conflict
     | Keeper_internal_error.Other_detail _ ->
       rotate Runtime_exhausted)
  | Keeper_internal_error.Accept_rejected _ ->
    (match Keeper_internal_error.accept_no_progress_retry_kind internal with
     | Some `Empty_no_progress -> rotate No_progress_empty
     | Some `Thinking_only_no_progress -> rotate No_progress_thinking_only
     | Some `Truncated_no_progress -> rotate No_progress_truncated
     | None -> exhaust_failure Internal_opaque)
  | Keeper_internal_error.Internal_contract_rejected _
  | Keeper_internal_error.Receipt_persistence_failed _
  | Keeper_internal_error.Gate_replay_repair_required _ ->
    exhaust_failure Internal_opaque
  (* The host stopped this turn on purpose. Nothing about the provider failed,
     so there is no other candidate that would do better. *)
  | Keeper_internal_error.Host_stopped_turn _ -> exhaust_failure Internal_opaque
  (* A person queued behind this autonomous turn before its provider produced
     anything (RFC-0441). The abandoned candidate did not fail, so the route
     notes no rest or demotion against it (Exhausted_visible_alive notes
     none). The walk itself stops in [Keeper_turn_driver], which ends the lane
     on this error ahead of any overflow; the keeper settles the turn as
     skipped, not failed (#38094). *)
  | Keeper_internal_error.Preempted_before_first_token _ ->
    exhaust_failure Internal_opaque
  (* The runtime's transport closed. [route_of_provider_error] answers
     [observe_retry Server_error] for agent-core's [ProviderUnavailable]; the
     typed value must not change which runtime is tried next, so it answers
     the same. *)
  | Keeper_internal_error.Runtime_connection_closed _ ->
    observe_retry Server_error
  (* A local claim refuses the durable session before a provider attempt.
     Keep the turn exhausted without implying a response or attempted effect. *)
  | Keeper_internal_error.Official_client_recovery_required _ ->
    exhaust_failure Session_claim_refused
  (* The admission check refuses the history before provider dispatch
     ([Keeper_agent_run.provider_transcript_admission]): no request carried
     the turn's input. *)
  | Keeper_internal_error.Incomplete_tool_transcript _ ->
    exhaust_failure Transcript_refused
  | Keeper_internal_error.Terminal_effect_failed
      { failure_class; effect_disposition; _ } ->
    (match effect_disposition with
     | Tool_result.Proven_pre_effect ->
       (* A proven pre-effect rejection must remain correction-capable inside
          the provider turn and must never reach this terminal boundary. *)
       exhaust_failure Contract_violation
     | Tool_result.Proven_post_effect | Tool_result.Effect_outcome_unknown ->
       (match failure_class with
        | Tool_result.Dependency_unavailable ->
          exhaust_failure Terminal_effect_dependency_unavailable
        | Tool_result.Policy_rejection ->
          exhaust_failure Terminal_effect_policy_rejection
        | Tool_result.Runtime_failure ->
          exhaust_failure Terminal_effect_runtime_failure
        | Tool_result.Workflow_rejection ->
          exhaust_failure Terminal_effect_workflow_rejection
        | Tool_result.Operator_cancelled ->
          exhaust_failure Terminal_effect_operator_cancelled))
  | Keeper_internal_error.Provider_attempt_effect_fenced
      { effect_disposition; _ } ->
    (match effect_disposition with
     | Keeper_provider_attempt_effect_core.No_effect_observed ->
       exhaust_failure Contract_violation
     | Keeper_provider_attempt_effect_core.Effect_attempted ->
       exhaust_failure (Provider_attempt_effect_fenced Fenced_effect_attempted)
     | Keeper_provider_attempt_effect_core.Observation_unavailable ->
       exhaust_failure
         (Provider_attempt_effect_fenced Fenced_observation_unavailable))
  | Keeper_internal_error.Tool_correction_lost { effect_disposition; _ } ->
    (match effect_disposition with
     | Keeper_provider_attempt_effect_core.No_effect_observed ->
       exhaust_failure Contract_violation
     | Keeper_provider_attempt_effect_core.Effect_attempted ->
       exhaust_failure (Tool_correction_lost Fenced_effect_attempted)
     | Keeper_provider_attempt_effect_core.Observation_unavailable ->
       exhaust_failure (Tool_correction_lost Fenced_observation_unavailable))
  | Keeper_internal_error.Internal_unhandled_exception _
  | Keeper_internal_error.Internal_bridge_exception _ ->
    exhaust_failure Internal_opaque

let route_of_api_error ~err (api : Llm_provider.Retry.api_error) =
  let exhaust_failure = exhaust ~err ~provenance:Agent_core_api_error in
  match api with
  | Llm_provider.Retry.RateLimited { retry_after; _ } ->
    observe_retry ?retry_after Rate_limited
  | Llm_provider.Retry.PaymentRequired _ -> observe_retry Hard_quota
  | Llm_provider.Retry.Overloaded _ -> observe_retry Provider_capacity
  | Llm_provider.Retry.ServerError _ -> observe_retry Server_error
  | Llm_provider.Retry.AuthError _
  | Llm_provider.Retry.AuthorizationError _ ->
    rotate Auth_failed
  | Llm_provider.Retry.NotFound _ -> rotate Model_unavailable
  | Llm_provider.Retry.NetworkError _ -> observe_retry Network_transient
  | Llm_provider.Retry.Timeout _ -> observe_retry Provider_timeout
  (* [Attempt_rejected] is masc's own pre-wire refusal (the candidate's
     reasoning-effort ladder or an explicit disable, folded through
     [Http_client.AcceptRejected]); the driver rotates on it, and a route
     that called it deterministic labelled a rotating failure as terminal
     (#33057). *)
  | Llm_provider.Retry.InvalidRequest { reason = Llm_provider.Retry.Attempt_rejected; _ } ->
    rotate Attempt_rejected
  (* The provider refused and the body that would have named the cause did
     not arrive before the caller's window closed. Nothing says the request
     is what it refused, so the lane moves to its next candidate rather than
     ending the turn on a reason nobody read. *)
  | Llm_provider.Retry.InvalidRequest
      { reason = Llm_provider.Retry.Refusal_body_not_received; _ } ->
    rotate Refusal_body_not_received
  (* The provider refused this body, with no machine-readable reason or
     with a size status. Another declared candidate may accept the same
     semantic input (a larger window, a different vendor's schema), and
     [attempt_rejected_should_try_next] moves the lane there in the same
     turn (#37631), so the route names that rotation. The same body to the
     same path is refused again, which [route_resumes_on_same_path] says. *)
  | Llm_provider.Retry.InvalidRequest
      { reason =
          ( Llm_provider.Retry.Request_body_refused_by_provider _
          | Llm_provider.Retry.Unknown_invalid_request )
      ; _
      } ->
    rotate Request_refused
  (* No walk predicate moves on a JSON parse failure, so the route keeps it
     terminal too. *)
  | Llm_provider.Retry.InvalidRequest { reason = Llm_provider.Retry.Json_parse_error; _ } ->
    exhaust_failure Deterministic_request
  | Llm_provider.Retry.ContextOverflow _ -> exhaust_failure Context_overflow
  | Llm_provider.Retry.InputCapacity _ -> exhaust_failure Deterministic_request

let route_of_provider_error ~err (p : Llm_provider.Error.provider_error) =
  let exhaust_failure = exhaust ~err ~provenance:Agent_core_provider_error in
  match p with
  | Llm_provider.Error.RateLimit { retry_after; _ } -> observe_retry ?retry_after Rate_limited
  | Llm_provider.Error.HardQuota { retry_after; _ } -> observe_retry ?retry_after Hard_quota
  | Llm_provider.Error.CapacityExhausted { retry_after; _ } ->
    observe_retry ?retry_after Provider_capacity
  | Llm_provider.Error.ProviderUnavailable _ -> observe_retry Server_error
  | Llm_provider.Error.EmptyCompletion { stop_reason; _ } ->
    observe_retry (Empty_completion { stop_reason })
  | Llm_provider.Error.ServerError { transient = true; _ } ->
    observe_retry Server_error
  (* The provider said this 5xx is not transient, so the same path answers
     the same way; a different candidate is a different server. The walk
     ([Runtime_attempt_fsm.should_try_next]) and this route both read the
     server-failure class from [Retry.server_status_class_of_code]. A code
     outside it is not a server failure the walk moves on. *)
  | Llm_provider.Error.ServerError { transient = false; code; _ } ->
    (match Llm_provider.Retry.server_status_class_of_code code with
     | Some (Llm_provider.Retry.Overloaded_status | Llm_provider.Retry.Server_error_status)
       -> rotate Server_error_not_transient
     | None -> exhaust_failure Provider_integration)
  | Llm_provider.Error.NetworkError _ -> observe_retry Network_transient
  | Llm_provider.Error.Timeout _ -> observe_retry Provider_timeout
  | Llm_provider.Error.AuthError _
  | Llm_provider.Error.AuthorizationError _ ->
    rotate Auth_failed
  | Llm_provider.Error.NotFound _ -> rotate Model_unavailable
  (* The model repeated itself and the stream was ended for it. The bytes
     were intact, so this is not a provider integration defect: the lane
     rotates to a different model. Crash accounting is class-blind (#32105)
     and unchanged by this route; what changes is the class label and that
     the model is known to have answered ([response_observed]). *)
  | Llm_provider.Error.RepeatingGeneration _ -> rotate Generation_repeated
  (* The provider reported a structured failure of its own for this attempt
     (a CLI-adapter turn failure, an RPC error, a post-activity context-window
     report). [Runtime_attempt_fsm.should_try_next] already rotates on every
     [Http_client.ProviderFailure] kind, the same wire family as
     [RepeatingGeneration] above; calling this class terminal disagreed with
     a walk that was already moving on (task-1642, census
     "provider:reported_error" rotates=true). Unlike the wire-format defects
     below, the same bytes do not have to arrive again: a different candidate
     is a different provider attempt that may not repeat this provider's own
     report. *)
  | Llm_provider.Error.ProviderReportedError _ -> rotate Provider_reported_failure
  | Llm_provider.Error.MissingApiKey _ -> exhaust_failure Config_mismatch
  | Llm_provider.Error.InvalidConfig _ -> exhaust_failure Config_mismatch
  | Llm_provider.Error.InvalidRequest _ -> exhaust_failure Deterministic_request
  (* The stream ended before the completion contract's stop reason. The
     provider accepted the request and the bytes that would have said why the
     generation stopped never arrived, which is what a dropped transport looks
     like. *)
  | Llm_provider.Error.ProviderWireError
      { kind = Llm_provider.Http_client.Incomplete_stream; _ } ->
    observe_retry Network_transient
  (* The bytes that did arrive broke this provider's declared wire format.
     The same path sends the same bytes again, but the next candidate is a
     different provider attempt with its own stream, and the walk already
     rotates on every [Http_client.ProviderFailure] kind. *)
  | Llm_provider.Error.ProviderWireError
      { kind =
          ( Llm_provider.Http_client.Malformed_payload
          | Llm_provider.Http_client.Unknown_event
          | Llm_provider.Http_client.Oversized_payload )
      ; _
      } ->
    rotate Provider_wire_defect
  (* [ParseError] and [UnknownVariant] are our own reading of the reply,
     which every candidate reaches; [ProviderTerminal] is a condition the
     provider ended its stream on (a session conflict among them). The walk
     carries all three as [Http_client.ProviderTerminal] and stops. *)
  | Llm_provider.Error.ParseError _
  | Llm_provider.Error.UnknownVariant _
  | Llm_provider.Error.ProviderTerminal _ ->
    exhaust_failure Provider_integration

let provenance_for_boundary boundary agent_core_provenance =
  match boundary with
  | Agent_core_execution -> agent_core_provenance
  | Masc_execution -> Masc_internal_error
;;

let route_of_error_family ~boundary (err : Agent_core.Error.t) : route =
  let exhaust_failure provenance terminal =
    exhaust ~err ~provenance:(provenance_for_boundary boundary provenance) terminal
  in
  match err with
  | Agent_core.Error.Api api -> route_of_api_error ~err api
  | Agent_core.Error.Provider p -> route_of_provider_error ~err p
  | Agent_core.Error.Mcp _ ->
    exhaust_failure Agent_core_mcp_error Protocol_error
  | Agent_core.Error.Config _ ->
    exhaust_failure Agent_core_config_error Config_mismatch
  | Agent_core.Error.Agent _ ->
    exhaust_failure Agent_core_agent_error Internal_opaque
  | Agent_core.Error.Serialization _ ->
    exhaust_failure Agent_core_serialization_error Internal_opaque
  | Agent_core.Error.Io _ ->
    exhaust_failure Agent_core_io_error Internal_opaque
  | Agent_core.Error.Orchestration _ ->
    exhaust_failure Agent_core_orchestration_error Internal_opaque
  | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried { message = _; _ } ->
    exhaust_failure Agent_core_internal_error Internal_opaque
;;

let route_of_error ~boundary (err : Agent_core.Error.t) : route =
  match Keeper_internal_error.classify_masc_internal_error err with
  (* Both of these decide their own route whichever boundary reported them.
     [Terminal_effect_failed] because the effect is the fact, and
     [Runtime_connection_closed] because the agent-core family arm would read
     its carrier as a bare internal error and drop the retry the untyped
     [ProviderUnavailable] used to earn (RFC-0454 P2). *)
  | Some
      (( Keeper_internal_error.Terminal_effect_failed _
       | Keeper_internal_error.Runtime_connection_closed _ ) as internal) ->
    route_of_masc_internal ~err internal
  | Some internal ->
    (match boundary with
     | Masc_execution -> route_of_masc_internal ~err internal
     | Agent_core_execution -> route_of_error_family ~boundary err)
  | None -> route_of_error_family ~boundary err

(* A provider's retry hint that names a wait: present, finite, above zero. *)
let usable_retry_after = function
  | None -> None
  | Some hint when Float.is_finite hint && hint > 0.0 -> Some hint
  | Some _ -> None
;;

(* How long a path rests after a provider refused it (RFC-provider-path-rest).
   The rest belongs to the path that received the answer, so its length comes
   from that answer alone: the keeper's cadence spaces periodic turns and says
   nothing about a provider's window.

   A usable hint rests that long. A positive fractional hint still rests at
   least one second so the chat lane cannot re-fire in a tight loop (#35246).
   Without a usable hint (absent, zero, negative, infinite, NaN) the class decides: a
   throttle rests the named floor, and an account exhaustion rests the cap,
   because a quota that said nothing about its end is not known to come back
   within a minute. Every result is clamped to [cap_sec] so a misread header
   cannot park a path longer than the operator allows. *)
let path_rest_sec ~cap_sec ~retry_class ~retry_after_hint =
  let cap_sec = Float.max 0.0 cap_sec in
  let unstated () =
    match retry_class with
    | Hard_quota -> cap_sec
    | Rate_limited
    | Provider_capacity
    | Empty_completion _
    | Server_error
    | Network_transient
    | Provider_timeout ->
      Env_config_keeper.KeeperKeepalive.rate_limit_backoff_floor_sec
  in
  let base =
    match usable_retry_after retry_after_hint with
    | None -> unstated ()
    | Some hint -> Float.max hint 1.0
  in
  Float.min cap_sec base
;;

let route_kind_label = function
  | Retry_after_observed _ -> "retry_after_observed"
  | Rotate_now _ -> "rotate_now"
  | Exhausted_visible_alive _ -> "exhausted_visible_alive"

let retry_class_label = function
  | Rate_limited -> "rate_limited"
  | Hard_quota -> "hard_quota"
  | Provider_capacity -> "provider_capacity"
  | Empty_completion { stop_reason } ->
    "empty_completion_" ^ Llm_provider.Types.stop_reason_to_metric_label stop_reason
  | Server_error -> "server_error"
  | Network_transient -> "network_transient"
  | Provider_timeout -> "provider_timeout"

let rotate_class_label = function
  | Auth_failed -> "auth_failed"
  | Model_unavailable -> "model_unavailable"
  | Resumable_cli_session -> "resumable_cli_session"
  | Candidates_filtered -> "candidates_filtered"
  | Runtime_exhausted -> "runtime_exhausted"
  | No_progress_empty -> "no_progress_empty"
  | No_progress_thinking_only -> "no_progress_thinking_only"
  | No_progress_truncated -> "no_progress_truncated"
  | Attempt_rejected -> "attempt_rejected"
  | Refusal_body_not_received -> "refusal_body_not_received"
  | Generation_repeated -> "generation_repeated"
  | Provider_reported_failure -> "provider_reported_failure"
  | Request_refused -> "request_refused"
  | Provider_wire_defect -> "provider_wire_defect"
  | Server_error_not_transient -> "server_error_not_transient"

let terminal_class_label = function
  | Deterministic_request -> "deterministic_request"
  | Context_overflow -> "context_overflow"
  | Session_claim_refused -> "session_claim_refused"
  | Transcript_refused -> "transcript_refused"
  | Contract_violation -> "contract_violation"
  | Protocol_error -> "protocol_error"
  | Config_mismatch -> "config_mismatch"
  | Provider_integration -> "provider_integration"
  | Terminal_effect_dependency_unavailable ->
    "terminal_effect_dependency_unavailable"
  | Terminal_effect_policy_rejection -> "terminal_effect_policy_rejection"
  | Terminal_effect_runtime_failure -> "terminal_effect_runtime_failure"
  | Terminal_effect_workflow_rejection -> "terminal_effect_workflow_rejection"
  | Terminal_effect_operator_cancelled -> "terminal_effect_operator_cancelled"
  | Provider_attempt_effect_fenced Fenced_effect_attempted ->
    "provider_attempt_effect_fenced"
  | Provider_attempt_effect_fenced Fenced_observation_unavailable ->
    "provider_attempt_effect_fenced_observation_unavailable"
  | Tool_correction_lost Fenced_effect_attempted -> "tool_correction_lost"
  | Tool_correction_lost Fenced_observation_unavailable ->
    "tool_correction_lost_observation_unavailable"
  | Internal_opaque -> "internal_opaque"

let route_class_label = function
  | Retry_after_observed { retry_class; _ } -> retry_class_label retry_class
  | Rotate_now { rotate } -> rotate_class_label rotate
  | Exhausted_visible_alive { terminal; _ } -> terminal_class_label terminal

(* Whether the provider answered the request that carried the turn's input.
   Read by the heartbeat to settle a Gate continuation that failed on this
   route: an answer means the model already saw the replay evidence the turn
   carried (#32956). Every constructor is named so a new class has to say
   which side it is on. *)
let response_observed = function
  | Retry_after_observed { retry_class; retry_after = _ } ->
    (match retry_class with
     | Empty_completion _ ->
       (* The provider completed the turn with a modeled stop reason and an
          empty assistant answer. The model saw the input even though it made
          no usable progress. *)
       true
     | Rate_limited
     (* 429: the request was refused before any generation. *)
     | Hard_quota
     (* 402: refused before any generation. *)
     | Provider_capacity
     (* the provider's overload or capacity pool: refused before any
        generation. *)
     | Server_error
     (* 5xx or provider unavailable: nothing the model said is on record. *)
     | Network_transient
     (* the transport failed; no answer arrived. *)
     | Provider_timeout ->
       (* the deadline expired before an answer. *)
       false)
  | Rotate_now { rotate } ->
    (match rotate with
     | Auth_failed
     (* the credential was refused before any generation. *)
     | Model_unavailable
     (* the model or endpoint was not found: no generation. *)
     | Resumable_cli_session
     (* the CLI session ended without an answer; a recovery lane resumes it. *)
     | Candidates_filtered
     (* the candidate set emptied before any answer. *)
     | Attempt_rejected
     (* the candidate's own policy refused the request before the wire
        (#34475): no generation. *)
     | Refusal_body_not_received
     (* the provider refused the request; the body naming why never
        arrived, and a refusal is not an answer. *)
     | Provider_reported_failure
     (* the provider reported its own structured failure for this attempt;
        unlike [Generation_repeated] below, nothing here says the model
        produced content the turn's input carried into. *)
     | Request_refused
     (* the provider refused the body before any generation. *)
     | Provider_wire_defect
     (* the bytes that arrived broke the wire format: no usable answer is on
        record. *)
     | Server_error_not_transient
     (* a 5xx: nothing the model said is on record. *)
     | Runtime_exhausted ->
       (* a whole-runtime exhaustion wrapper: it carries no answer. *)
       false
     | No_progress_empty
     (* the provider answered with an empty body and the accept gate
        rejected that answer. *)
     | No_progress_thinking_only
     (* the provider answered with thinking only; rejected by the accept
        gate. *)
     | No_progress_truncated
     (* the provider answered and stopped at MaxTokens; rejected by the
        accept gate. *)
     | Generation_repeated ->
       (* the model answered and kept repeating one unit; the client ended
          the stream, so the input was seen. *)
       true)
  | Exhausted_visible_alive { terminal; provenance = _; detail = _ } ->
    (match terminal with
     | Deterministic_request
     (* invalid request or input capacity: refused before any generation. *)
     | Context_overflow
     (* the request did not fit the window: no generation. *)
     | Session_claim_refused
     (* the durable local session claim was refused before dispatch; the
        model did not see the turn input or its replay evidence. *)
     | Transcript_refused
     (* the history was refused before dispatch; the model did not see the
        turn input or its replay evidence. *)
     | Protocol_error
     (* an MCP protocol failure; whether an answer arrived is not on the
        route. *)
     | Config_mismatch
     (* missing key or invalid configuration: no generation. *)
     | Provider_integration
     (* unparseable, provider-reported, or unknown-variant reply: no usable
        answer is on record. *)
     | Internal_opaque
     (* unhandled exceptions and internal families. An accept rejection
        without a no-progress hint also lands here, but the route cannot
        tell it from an exception, so the evidence keeps its wake. *)
     | Provider_attempt_effect_fenced Fenced_observation_unavailable
     | Tool_correction_lost Fenced_observation_unavailable ->
       (* the adapter could not say whether a tool effect was attempted,
          and it says so before any answer: the claude-code lane marks it
          when the process is spawned ([Keeper_claude_code_runtime]
          on_spawned), the codex lane when the turn input could not be
          written ([Keeper_codex_runtime] Turn_input_write_failed). The
          request may never have reached the provider, so the evidence
          keeps its wake. *)
       false
     | Contract_violation
     (* a proven pre-effect tool failure: the model answered and the turn's
        own contract over that answer failed. The two effect fences reach
        this class only with [No_effect_observed], which the driver never
        produces. *)
     | Terminal_effect_dependency_unavailable
     | Terminal_effect_policy_rejection
     | Terminal_effect_runtime_failure
     | Terminal_effect_workflow_rejection
     | Terminal_effect_operator_cancelled
     (* a tool the model called failed terminally: the call is the answer. *)
     | Provider_attempt_effect_fenced Fenced_effect_attempted
     (* a dynamic tool handler was entered before the attempt was fenced
        ([Keeper_turn_driver], masc#28885): the model answered with that
        call, and what failed came after it. *)
     | Tool_correction_lost Fenced_effect_attempted ->
       (* the same fence on a turn that also recorded pre_tool_use
          rejections: the model answered, the correction round did not
          land. *)
       true)

let route_resumes_on_same_path = function
  | Retry_after_observed { retry_class; retry_after } ->
    (match retry_class with
     | Rate_limited
     (* 429: the provider lifts the throttle over time. A weekly limit sent as
        a 429 fails the resumed attempt before it runs a tool, which ends the
        operation. *)
     | Provider_capacity
     (* the provider's capacity was full for the moment. *)
     | Empty_completion
         { stop_reason =
             ( Llm_provider.Types.EndTurn | Llm_provider.Types.MaxTokens
             | Llm_provider.Types.StopSequence )
         }
     (* A direct operation that saved tool results resumes once from that
        checkpoint rather than discarding the work. If the empty answer
        repeats before another tool result is saved, the progress condition
        withholds a second resume. *)
     | Server_error
     (* 5xx or provider unavailable. *)
     | Network_transient
     (* the transport dropped. *)
     | Provider_timeout ->
       (* a deadline expired. *)
       true
     | Empty_completion
         { stop_reason =
             ( Llm_provider.Types.Refusal | Llm_provider.Types.ContentFilter
             | Llm_provider.Types.RepetitionTruncation
             | Llm_provider.Types.StopToolUse | Llm_provider.Types.PauseTurn
             | Llm_provider.Types.Compaction
             | Llm_provider.Types.ContextWindowExceeded
             | Llm_provider.Types.UnmatchedToolCalls | Llm_provider.Types.Unknown _ )
         } ->
       (* Refusal, content filtering, and repetition truncation are
          deterministic for the same input, matching
          [Refusal_body_not_received] and [Generation_repeated] below.
          [PauseTurn] and [Compaction] require replaying the provider's actual
          assistant response. An [EmptyCompletion] error carries no response
          content, so replaying the pre-response checkpoint is not that
          continuation. Context overflow and unknown reasons normally become
          typed API errors before this boundary; keep injected values closed
          rather than guessing a same-path recovery. *)
       false
     | Hard_quota ->
       (* a quota comes back by itself only when the provider said when; one
          with no reset may stay closed until the account is paid. *)
       Option.is_some (usable_retry_after retry_after))
  | Rotate_now { rotate } ->
    (match rotate with
     | Auth_failed
     | Model_unavailable
     | Resumable_cli_session
     | Candidates_filtered
     | Runtime_exhausted
     | No_progress_empty
     | No_progress_thinking_only
     | No_progress_truncated
     | Refusal_body_not_received
     | Generation_repeated
     | Attempt_rejected
     | Provider_reported_failure
     | Request_refused
     | Provider_wire_defect
     | Server_error_not_transient ->
       (* the credential, the model, the client session, the request body,
          the provider's wire or its own non-transient answer: the same path
          answers the same way after any wait. *)
       false)
  | Exhausted_visible_alive { terminal; provenance = _; detail = _ } ->
    (match terminal with
     | Deterministic_request
     | Context_overflow
     | Session_claim_refused
     | Transcript_refused
     | Contract_violation
     | Protocol_error
     | Config_mismatch
     | Provider_integration
     | Terminal_effect_dependency_unavailable
     | Terminal_effect_policy_rejection
     | Terminal_effect_runtime_failure
     | Terminal_effect_workflow_rejection
     | Terminal_effect_operator_cancelled
     | Provider_attempt_effect_fenced
         (Fenced_effect_attempted | Fenced_observation_unavailable)
     | Tool_correction_lost (Fenced_effect_attempted | Fenced_observation_unavailable)
     | Internal_opaque ->
       (* the request, its size, the configuration, a tool, or MASC itself
          failed: sending it again to the same path fails the same way. *)
       false)
