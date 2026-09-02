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
  | Provider_attempt_effect_fenced
  | Tool_correction_lost
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
     | Keeper_provider_attempt_effect_core.Effect_attempted
     | Keeper_provider_attempt_effect_core.Observation_unavailable ->
       exhaust_failure Provider_attempt_effect_fenced)
  | Keeper_internal_error.Tool_correction_lost { effect_disposition; _ } ->
    (match effect_disposition with
     | Keeper_provider_attempt_effect_core.No_effect_observed ->
       exhaust_failure Contract_violation
     | Keeper_provider_attempt_effect_core.Effect_attempted
     | Keeper_provider_attempt_effect_core.Observation_unavailable ->
       exhaust_failure Tool_correction_lost)
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
  | Llm_provider.Retry.InvalidRequest _ -> exhaust_failure Deterministic_request
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
  | Provider_attempt_effect_fenced -> "provider_attempt_effect_fenced"
  | Tool_correction_lost -> "tool_correction_lost"
  | Internal_opaque -> "internal_opaque"

let route_class_label = function
  | Retry_after_observed { retry_class; _ } -> retry_class_label retry_class
  | Rotate_now { rotate } -> rotate_class_label rotate
  | Exhausted_visible_alive { terminal; _ } -> terminal_class_label terminal
