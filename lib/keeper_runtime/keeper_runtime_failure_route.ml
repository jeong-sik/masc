(* Total typed failure routing. See keeper_runtime_failure_route.mli. *)

type retry_class =
  | Rate_limited
  | Hard_quota
  | Capacity_backpressure
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
  | Attempt_rejected

type fence_disposition =
  | Fenced_effect_attempted
  | Fenced_observation_unavailable

type terminal_class =
  | Deterministic_request
  | Context_overflow
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

let retry_after_of_capacity_hint = function
  | Keeper_internal_error.Explicit sec -> Some sec
  | Keeper_internal_error.No_retry_hint -> None

let route_of_masc_internal ~err (internal : Keeper_internal_error.masc_internal_error) =
  let exhaust_failure = exhaust ~err ~provenance:Masc_internal_error in
  match internal with
  | Keeper_internal_error.Resumable_cli_session _ -> rotate Resumable_cli_session
  | Keeper_internal_error.Capacity_backpressure { retry_after; _ } ->
    observe_retry ?retry_after:(retry_after_of_capacity_hint retry_after) Capacity_backpressure
  | Keeper_internal_error.Runtime_exhausted { reason; _ } ->
    (match reason with
     | Keeper_internal_error.Capacity_exhausted -> observe_retry Capacity_backpressure
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
  | Keeper_internal_error.Incomplete_tool_transcript _ ->
    exhaust_failure Contract_violation
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
  | Llm_provider.Retry.Overloaded _ -> observe_retry Capacity_backpressure
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
     (#33057). The provider-side reasons stay terminal: a body the provider
     itself refused does not change on the next candidate. *)
  | Llm_provider.Retry.InvalidRequest { reason = Llm_provider.Retry.Attempt_rejected; _ } ->
    rotate Attempt_rejected
  | Llm_provider.Retry.InvalidRequest
      { reason =
          ( Llm_provider.Retry.Json_parse_error
          | Llm_provider.Retry.Request_body_too_large _
          | Llm_provider.Retry.Request_body_refused_by_provider _
          | Llm_provider.Retry.Unknown_invalid_request )
      ; _
      } ->
    exhaust_failure Deterministic_request
  | Llm_provider.Retry.ContextOverflow _ -> exhaust_failure Context_overflow
  | Llm_provider.Retry.InputCapacity _ -> exhaust_failure Deterministic_request

let route_of_provider_error ~err (p : Llm_provider.Error.provider_error) =
  let exhaust_failure = exhaust ~err ~provenance:Agent_core_provider_error in
  match p with
  | Llm_provider.Error.RateLimit { retry_after; _ } -> observe_retry ?retry_after Rate_limited
  | Llm_provider.Error.HardQuota { retry_after; _ } -> observe_retry ?retry_after Hard_quota
  | Llm_provider.Error.CapacityExhausted { retry_after; _ } ->
    observe_retry ?retry_after Capacity_backpressure
  | Llm_provider.Error.ProviderUnavailable _
  | Llm_provider.Error.EmptyCompletion _ -> observe_retry Server_error
  | Llm_provider.Error.ServerError { transient = true; _ } ->
    observe_retry Server_error
  | Llm_provider.Error.ServerError { transient = false; _ } ->
    exhaust_failure Provider_integration
  | Llm_provider.Error.NetworkError _ -> observe_retry Network_transient
  | Llm_provider.Error.Timeout _ -> observe_retry Provider_timeout
  | Llm_provider.Error.AuthError _
  | Llm_provider.Error.AuthorizationError _ ->
    rotate Auth_failed
  | Llm_provider.Error.NotFound _ -> rotate Model_unavailable
  | Llm_provider.Error.MissingApiKey _ -> exhaust_failure Config_mismatch
  | Llm_provider.Error.InvalidConfig _ -> exhaust_failure Config_mismatch
  | Llm_provider.Error.InvalidRequest _ -> exhaust_failure Deterministic_request
  | Llm_provider.Error.ParseError _
  | Llm_provider.Error.ProviderWireError _
  | Llm_provider.Error.ProviderReportedError _
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
  | Some (Keeper_internal_error.Terminal_effect_failed _ as internal) ->
    route_of_masc_internal ~err internal
  | Some internal ->
    (match boundary with
     | Masc_execution -> route_of_masc_internal ~err internal
     | Agent_core_execution -> route_of_error_family ~boundary err)
  | None -> route_of_error_family ~boundary err

let retry_after_of_route = function
  | Retry_after_observed { retry_after; _ } -> retry_after
  | Rotate_now _ -> None
  | Exhausted_visible_alive _ -> None

(* A provider rate-limit ([429]) or capacity failure route means the lane
   itself is the thing that must back off: re-running the turn at the plain
   cadence keeps hammering the provider while the crash-accounting streak
   climbs like a clock (#26068). [retry_backoff_sec] derives the backoff from
   the route's own [Retry-After] hint when present, else from the cadence, and
   always clamps to the configured cap so a misread hint (or an out-of-range
   env override) cannot park the lane for longer than the cap. Both lanes that
   retry against a provider share this one rule: the heartbeat cycle sleep and
   the chat lane's deferred-retry [not_before]. *)
let retry_backoff_sec ~cap_sec ~retry_after_hint ~cadence_sec =
  let cap_sec = Float.max 0.0 cap_sec in
  let retry_after_hint = Option.value ~default:0.0 retry_after_hint in
  (* A garbage [Retry-After] (negative, NaN, infinite) is still a signal the
     provider rate-limited this lane, but carries no usable duration: both
     degrade to the same bounded default rather than diverging. *)
  let base =
    if Float.is_nan retry_after_hint || retry_after_hint <= 0.0
    then Float.max cadence_sec 60.0
    else Float.max retry_after_hint cadence_sec
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
  | Capacity_backpressure -> "capacity_backpressure"
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

let terminal_class_label = function
  | Deterministic_request -> "deterministic_request"
  | Context_overflow -> "context_overflow"
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
     | Rate_limited
     (* 429: the request was refused before any generation. *)
     | Hard_quota
     (* 402: refused before any generation. *)
     | Capacity_backpressure
     (* overload / capacity pool exhausted: refused before any generation. *)
     | Server_error
     (* 5xx, provider unavailable, or an empty completion: nothing the model
        said is on record. *)
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
     | Runtime_exhausted ->
       (* a whole-runtime exhaustion wrapper: it carries no answer. *)
       false
     | No_progress_empty
     (* the provider answered with an empty body and the accept gate
        rejected that answer. *)
     | No_progress_thinking_only
     (* the provider answered with thinking only; rejected by the accept
        gate. *)
     | No_progress_truncated ->
       (* the provider answered and stopped at MaxTokens; rejected by the
          accept gate. *)
       true)
  | Exhausted_visible_alive { terminal; provenance = _; detail = _ } ->
    (match terminal with
     | Deterministic_request
     (* invalid request or input capacity: refused before any generation. *)
     | Context_overflow
     (* the request did not fit the window: no generation. *)
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
     (* an incomplete tool transcript or a proven pre-effect tool failure:
        the model answered and the turn's own contract over that answer
        failed. The two effect fences reach this class only with
        [No_effect_observed], which the driver never produces. *)
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
