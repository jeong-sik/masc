(* RFC-0313 W2 — total failure routing. See keeper_runtime_failure_route.mli. *)

type pacing_class =
  | Rate_limited
  | Hard_quota
  | Capacity_backpressure
  | Server_error
  | Network_transient
  | Provider_timeout
  | Turn_timeout
  | Admission_backpressure

type rotate_class =
  | Auth_failed
  | Model_unavailable
  | Resumable_cli_session
  | Candidates_filtered
  | Runtime_exhausted
  | No_progress_empty
  | No_progress_read_only
  | No_progress_thinking_only

type judgment_class =
  | Deterministic_request
  | Context_overflow
  | Contract_violation
  | Mutating_ambiguity
  | Protocol_error
  | Config_mismatch
  | Provider_integration
  | Internal_opaque

type route =
  | Retry_after_pacing of
      { pacing : pacing_class
      ; retry_after : float option
      }
  | Rotate_now of { rotate : rotate_class }
  | Escalate_judgment of
      { judgment : judgment_class
      ; detail : string
      }

(* Cloudflare gateway timeout surfaces provider congestion, not provider
   fault. Same predicate as [Keeper_error_classify.is_gateway_backpressure_status]
   (lib/keeper, above this library); consolidation to one site is RFC-0313 W5
   boundary cleanup. *)
let cloudflare_gateway_timeout_status = 524

let is_gateway_backpressure_status status =
  status = cloudflare_gateway_timeout_status

let pacing ?retry_after pacing_class =
  Retry_after_pacing { pacing = pacing_class; retry_after }

let rotate rotate_class = Rotate_now { rotate = rotate_class }

let judgment_detail err =
  Keeper_internal_error.cap_blocker_detail (Agent_sdk.Error.to_string err)

let judge ~err judgment_class =
  Escalate_judgment { judgment = judgment_class; detail = judgment_detail err }

let retry_after_of_capacity_hint = function
  | Keeper_internal_error.Explicit sec -> Some sec
  | Keeper_internal_error.Synthetic_default sec -> Some sec
  | Keeper_internal_error.No_retry_hint -> None

let route_of_masc_internal ~err (internal : Keeper_internal_error.masc_internal_error) =
  match internal with
  | Keeper_internal_error.Resumable_cli_session _ -> rotate Resumable_cli_session
  | Keeper_internal_error.Admission_queue_timeout _ -> pacing Admission_backpressure
  | Keeper_internal_error.Admission_queue_rejected _ -> pacing Admission_backpressure
  | Keeper_internal_error.Provider_timeout _ -> pacing Provider_timeout
  | Keeper_internal_error.Turn_timeout _ -> pacing Turn_timeout
  | Keeper_internal_error.Capacity_backpressure { retry_after; _ } ->
    pacing ?retry_after:(retry_after_of_capacity_hint retry_after) Capacity_backpressure
  | Keeper_internal_error.Runtime_exhausted { reason; _ } ->
    (match reason with
     | Keeper_internal_error.Capacity_exhausted -> pacing Capacity_backpressure
     | Keeper_internal_error.Candidates_filtered_after_cycles ->
       rotate Candidates_filtered
     | Keeper_internal_error.Connection_refused
     | Keeper_internal_error.Dns_failure ->
       pacing Network_transient
     | Keeper_internal_error.Structural_attempt_timeout _ -> pacing Provider_timeout
     | Keeper_internal_error.No_providers_available
     | Keeper_internal_error.All_providers_failed
     | Keeper_internal_error.Max_turns_exceeded
     | Keeper_internal_error.Other_detail _ ->
       rotate Runtime_exhausted)
  | Keeper_internal_error.Accept_rejected _ ->
    (match Keeper_internal_error.accept_no_progress_retry_kind internal with
     | Some `Empty_no_progress -> rotate No_progress_empty
     | Some `Read_only_no_progress -> rotate No_progress_read_only
     | Some `Thinking_only_no_progress -> rotate No_progress_thinking_only
     | None -> judge ~err Contract_violation)
  | Keeper_internal_error.Internal_contract_rejected _ -> judge ~err Contract_violation
  | Keeper_internal_error.Ambiguous_post_commit _ -> judge ~err Mutating_ambiguity
  | Keeper_internal_error.Internal_unhandled_exception _
  | Keeper_internal_error.Internal_bridge_exception _ ->
    judge ~err Internal_opaque

let route_of_api_error ~err (api : Llm_provider.Retry.api_error) =
  match api with
  | Llm_provider.Retry.RateLimited { retry_after; _ } ->
    if Llm_provider.Retry.is_hard_quota api
    then pacing ?retry_after Hard_quota
    else pacing ?retry_after Rate_limited
  | Llm_provider.Retry.PaymentRequired _ -> pacing Hard_quota
  | Llm_provider.Retry.Overloaded _ -> pacing Capacity_backpressure
  | Llm_provider.Retry.ServerError { status; _ } ->
    if is_gateway_backpressure_status status
    then pacing Capacity_backpressure
    else if status >= 500
    then pacing Server_error
    else judge ~err Provider_integration
  | Llm_provider.Retry.AuthError _
  | Llm_provider.Retry.AuthorizationError _ ->
    rotate Auth_failed
  | Llm_provider.Retry.NotFound _ -> rotate Model_unavailable
  | Llm_provider.Retry.NetworkError _ -> pacing Network_transient
  | Llm_provider.Retry.Timeout _ -> pacing Provider_timeout
  | Llm_provider.Retry.InvalidRequest _ -> judge ~err Deterministic_request
  | Llm_provider.Retry.ContextOverflow _ -> judge ~err Context_overflow

let route_of_provider_error ~err (p : Llm_provider.Error.provider_error) =
  match p with
  | Llm_provider.Error.RateLimit { retry_after; _ } -> pacing ?retry_after Rate_limited
  | Llm_provider.Error.HardQuota { retry_after; _ } -> pacing ?retry_after Hard_quota
  | Llm_provider.Error.CapacityExhausted { retry_after; _ } ->
    pacing ?retry_after Capacity_backpressure
  | Llm_provider.Error.ProviderUnavailable _ -> pacing Server_error
  | Llm_provider.Error.ServerError { code; transient; _ } ->
    if is_gateway_backpressure_status code
    then pacing Capacity_backpressure
    else if transient || code >= 500
    then pacing Server_error
    else judge ~err Provider_integration
  | Llm_provider.Error.NetworkError _ -> pacing Network_transient
  | Llm_provider.Error.Timeout _ -> pacing Provider_timeout
  | Llm_provider.Error.AuthError _
  | Llm_provider.Error.AuthorizationError _ ->
    rotate Auth_failed
  | Llm_provider.Error.NotFound _ -> rotate Model_unavailable
  | Llm_provider.Error.MissingApiKey _ -> judge ~err Config_mismatch
  | Llm_provider.Error.InvalidConfig _ -> judge ~err Config_mismatch
  | Llm_provider.Error.InvalidRequest _ -> judge ~err Deterministic_request
  | Llm_provider.Error.ParseError _
  | Llm_provider.Error.UnknownVariant _
  | Llm_provider.Error.ProviderTerminal _ ->
    judge ~err Provider_integration

let route_of_error (err : Agent_sdk.Error.sdk_error) : route =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some internal -> route_of_masc_internal ~err internal
  | None ->
    (match err with
     | Agent_sdk.Error.Api api -> route_of_api_error ~err api
     | Agent_sdk.Error.Provider p -> route_of_provider_error ~err p
     | Agent_sdk.Error.Mcp _ -> judge ~err Protocol_error
     | Agent_sdk.Error.Config _ -> judge ~err Config_mismatch
     | Agent_sdk.Error.Agent (Agent_sdk.Error.IdleDetected _) ->
       (* RFC-0313 W3: an idle loop (repeated no-usable-progress turns) was
          a manual-resume pause class on the legacy ladder; under existence
          invariance it escalates as a behavioral contract judgment, not as
          an opaque internal error. *)
       judge ~err Contract_violation
     | Agent_sdk.Error.Agent _
     | Agent_sdk.Error.Serialization _
     | Agent_sdk.Error.Io _
     | Agent_sdk.Error.Orchestration _
     | Agent_sdk.Error.Internal _ ->
       judge ~err Internal_opaque)

let retry_after_of_route = function
  | Retry_after_pacing { retry_after; _ } -> retry_after
  | Rotate_now _ -> None
  | Escalate_judgment _ -> None

let route_kind_label = function
  | Retry_after_pacing _ -> "retry_after_pacing"
  | Rotate_now _ -> "rotate_now"
  | Escalate_judgment _ -> "escalate_judgment"

let pacing_class_label = function
  | Rate_limited -> "rate_limited"
  | Hard_quota -> "hard_quota"
  | Capacity_backpressure -> "capacity_backpressure"
  | Server_error -> "server_error"
  | Network_transient -> "network_transient"
  | Provider_timeout -> "provider_timeout"
  | Turn_timeout -> "turn_timeout"
  | Admission_backpressure -> "admission_backpressure"

let rotate_class_label = function
  | Auth_failed -> "auth_failed"
  | Model_unavailable -> "model_unavailable"
  | Resumable_cli_session -> "resumable_cli_session"
  | Candidates_filtered -> "candidates_filtered"
  | Runtime_exhausted -> "runtime_exhausted"
  | No_progress_empty -> "no_progress_empty"
  | No_progress_read_only -> "no_progress_read_only"
  | No_progress_thinking_only -> "no_progress_thinking_only"

let judgment_class_label = function
  | Deterministic_request -> "deterministic_request"
  | Context_overflow -> "context_overflow"
  | Contract_violation -> "contract_violation"
  | Mutating_ambiguity -> "mutating_ambiguity"
  | Protocol_error -> "protocol_error"
  | Config_mismatch -> "config_mismatch"
  | Provider_integration -> "provider_integration"
  | Internal_opaque -> "internal_opaque"

let route_class_label = function
  | Retry_after_pacing { pacing; _ } -> pacing_class_label pacing
  | Rotate_now { rotate } -> rotate_class_label rotate
  | Escalate_judgment { judgment; _ } -> judgment_class_label judgment

let judgment_class_of_label = function
  | "deterministic_request" -> Some Deterministic_request
  | "context_overflow" -> Some Context_overflow
  | "contract_violation" -> Some Contract_violation
  | "mutating_ambiguity" -> Some Mutating_ambiguity
  | "protocol_error" -> Some Protocol_error
  | "config_mismatch" -> Some Config_mismatch
  | "provider_integration" -> Some Provider_integration
  | "internal_opaque" -> Some Internal_opaque
  | _ -> None
