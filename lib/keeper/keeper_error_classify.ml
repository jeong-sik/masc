(** Keeper_error_classify — Error classification, side-effect safety,
    and retry constants for the unified keeper cycle.

    Pure predicates and classification functions over [Agent_sdk.Error.sdk_error].
    No I/O, no state mutation.

    Extracted from keeper_unified_turn.ml.

    @since 0.122.0 *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

(** {1 Static ADT Classification}
    RFC-0314 / task-1854: Replace heuristic string-matching predicates with
    a static ADT that the compiler can exhaustively match. *)
type error_classification =
  | Transient_network
  | Transient_internal_runner
  | Transient_oas_timeout
  | Transient_rate_limit
  | Transient_capacity
  | Non_transient
  | Unclassified

let string_contains_substring = String_util.string_contains_substring

let is_structural_oas_timeout_message message =
  Keeper_oas_timeout_message.is_structural message

(** Detect transient network errors that warrant retry with short backoff.
    Uses structured [Agent_sdk.Error.sdk_error] pattern matching instead of
    substring matching on stringified error messages. *)
let is_transient_internal_transport_error = function
  | Llm_provider.Http_client.Tls_error -> true
  | Llm_provider.Http_client.Connection_refused
  | Llm_provider.Http_client.Dns_failure
  | Llm_provider.Http_client.Timeout
  | Llm_provider.Http_client.Local_resource_exhaustion
  | Llm_provider.Http_client.End_of_file
  | Llm_provider.Http_client.Unknown ->
    false
;;

let is_transient_internal_runner_error (err : Agent_sdk.Error.sdk_error) : bool =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some
      (Keeper_turn_driver.Internal_unhandled_exception
         { site; transport_error_kind = Some transport_error_kind; _ })
    when String.equal site Keeper_turn_driver.runtime_runner_execute_site ->
    is_transient_internal_transport_error transport_error_kind
  | Some
      ( Keeper_turn_driver.Internal_unhandled_exception _
      | Keeper_turn_driver.Runtime_exhausted _
      | Keeper_turn_driver.Capacity_backpressure _
      | Keeper_turn_driver.Resumable_cli_session _
      | Keeper_turn_driver.Accept_rejected _
      | Keeper_turn_driver.Admission_queue_timeout _
      | Keeper_turn_driver.Admission_queue_rejected _
      | Keeper_turn_driver.Provider_timeout _
      | Keeper_turn_driver.Turn_timeout _
      | Keeper_turn_driver.Ambiguous_post_commit _
      | Keeper_turn_driver.Internal_bridge_exception _
      | Keeper_turn_driver.Internal_contract_rejected _ )
  | None -> false

(** Classify an [sdk_error] into a static [error_classification] variant.
    Replaces the individual heuristic predicate functions with a single
    exhaustive match. *)
let classify_error (err : Agent_sdk.Error.sdk_error) : error_classification =
  if is_transient_internal_runner_error err
  then Transient_internal_runner
  else match err with
  | Agent_sdk.Error.Api (NetworkError _) -> Transient_network
  | Agent_sdk.Error.Api (Timeout { message }) ->
      if is_structural_oas_timeout_message message then Transient_oas_timeout
      else Transient_network
  | Agent_sdk.Error.Api (Overloaded _) -> Transient_capacity
  | Agent_sdk.Error.Api (ServerError { status = 503; _ }) -> Transient_network
  | Agent_sdk.Error.Api (ServerError { status = 522; _ }) -> Transient_network
  | Agent_sdk.Error.Api (ServerError { status = 524; _ }) -> Transient_network
  | Agent_sdk.Error.Api (RateLimited _) -> Transient_rate_limit
  | Agent_sdk.Error.Provider
      (Llm_provider.Error.NetworkError
         { kind =
             Llm_provider.Http_client.Tls_error
           | Llm_provider.Http_client.Local_resource_exhaustion
         ; _
         }) ->
      Non_transient
  | Agent_sdk.Error.Provider (Llm_provider.Error.NetworkError _) -> Transient_network
  | Agent_sdk.Error.Provider (Llm_provider.Error.Timeout { detail; _ }) ->
      if is_structural_oas_timeout_message detail then Transient_oas_timeout
      else Transient_network
  | Agent_sdk.Error.Provider (Llm_provider.Error.ServerError { code = 524; _ }) ->
      Transient_network
  | Agent_sdk.Error.Provider (Llm_provider.Error.ServerError { transient; _ }) ->
      if transient then Transient_network else Non_transient
  | Agent_sdk.Error.Provider (Llm_provider.Error.RateLimit _) -> Transient_rate_limit
  | Agent_sdk.Error.Provider (Llm_provider.Error.AuthError _) -> Non_transient
  | Agent_sdk.Error.Provider (Llm_provider.Error.ParseError _) -> Non_transient
  | Agent_sdk.Error.Provider (Llm_provider.Error.InvalidRequest _) -> Non_transient
  | Agent_sdk.Error.Provider (Llm_provider.Error.CapacityExhausted _) -> Transient_capacity
  | Agent_sdk.Error.Provider (Llm_provider.Error.HardQuota _) -> Non_transient
  | Agent_sdk.Error.Provider (Llm_provider.Error.ProviderUnavailable _) -> Non_transient
  | Agent_sdk.Error.Provider (Llm_provider.Error.ProviderTerminal _) -> Non_transient
  | Agent_sdk.Error.Provider (Llm_provider.Error.NotFound _) -> Non_transient
  | Agent_sdk.Error.Provider (Llm_provider.Error.MissingApiKey _) -> Non_transient
  | Agent_sdk.Error.Provider (Llm_provider.Error.InvalidConfig _) -> Non_transient
  | Agent_sdk.Error.Provider (Llm_provider.Error.UnknownVariant _) -> Unclassified
  | Agent_sdk.Error.Api (InvalidRequest _ | ServerError _ | AuthError _
    | NotFound _ | PaymentRequired _ | ContextOverflow _) -> Non_transient
  | Agent_sdk.Error.Agent _ | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _ | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _ | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.Internal _ -> Unclassified

(** {1 Retry & Side-Effect Safety}

    @boundary-contract
    - MASC owns: side-effect detection (blocking retry after mutating tools),
      cross-provider retry (2 attempts after all OAS per-provider retries
      exhaust), error reclassification for ambiguous outcomes.
    - OAS owns: per-provider retry (3 attempts), HTTP backoff, timeout
      handling, provider failover within a single runtime call.
    - Neither may: retry silently after a mutating tool succeeded (integrity
      over availability); duplicate OAS per-provider retry counts. *)

let is_transient_network_error (err : Agent_sdk.Error.sdk_error) : bool =
  if is_transient_internal_runner_error err
  then true
  else match err with
  | Agent_sdk.Error.Api (NetworkError _) -> true
  | Agent_sdk.Error.Api (Timeout { message }) ->
      not (is_structural_oas_timeout_message message)
  | Agent_sdk.Error.Provider (Llm_provider.Error.NetworkError
      { kind = Llm_provider.Http_client.Tls_error
             | Llm_provider.Http_client.Local_resource_exhaustion; _ }) ->
      false
  | Agent_sdk.Error.Provider (Llm_provider.Error.NetworkError _) -> true
  | Agent_sdk.Error.Provider (Llm_provider.Error.Timeout { detail; _ }) ->
      not (is_structural_oas_timeout_message detail)
  | Agent_sdk.Error.Api (Overloaded _) -> true
  | Agent_sdk.Error.Api (ServerError { status = 503; _ }) -> true
  (* Cloudflare 52x timeout family — origin server unreachable or
     slow to respond. Both are transient: a different provider may succeed
     where one origin timed out, so the runtime should advance. *)
  | Agent_sdk.Error.Api (ServerError { status = 522; _ }) -> true
  | Agent_sdk.Error.Api (ServerError { status = 524; _ }) -> true
  | Agent_sdk.Error.Provider (Llm_provider.Error.ServerError { code = 524; _ }) ->
      true
  | Agent_sdk.Error.Provider (Llm_provider.Error.ServerError { transient; _ }) ->
      transient
  (* Non-transient API errors. *)
  | Agent_sdk.Error.Api (ServerError _)
  | Agent_sdk.Error.Api (RateLimited _)
  | Agent_sdk.Error.Api (AuthError _)
  | Agent_sdk.Error.Api (PaymentRequired _)
  | Agent_sdk.Error.Api (InvalidRequest _)
  | Agent_sdk.Error.Api (NotFound _)
  | Agent_sdk.Error.Api (ContextOverflow _) -> false
  (* Non-API error families are by definition not transient network errors. *)
  | Agent_sdk.Error.Provider _
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.Internal _ -> false

(** Detect typed server-side request body parse errors.  The LLM API never
    processed the request, so committed tool results are not at risk of
    duplication.

    These errors may recur with the same payload, so they are NOT
    eligible for same-turn retry.  They ARE eligible for auto-recovery
    when all committed tools are reconcile-safe (idempotent/board-like):
    the keeper's next heartbeat cycle will build a fresh prompt.

    Deliberately do not infer this from [InvalidRequest] message text: provider
    bodies are free-form and have produced false positives for non-JSON parse
    errors.  If OAS needs to recover these cases, it must expose a structured
    parse-error constructor before MASC classifies them here. *)

let is_provider_rejected_parse_error (err : Agent_sdk.Error.sdk_error) : bool =
  match err with
  | Agent_sdk.Error.Provider (Llm_provider.Error.ParseError _) -> true
  | Agent_sdk.Error.Provider
      (Llm_provider.Error.InvalidRequest _ | Llm_provider.Error.NetworkError _
      | Llm_provider.Error.Timeout _
      | Llm_provider.Error.ServerError _ | Llm_provider.Error.RateLimit _
      | Llm_provider.Error.AuthError _ | Llm_provider.Error.MissingApiKey _
      | Llm_provider.Error.NotFound _ | Llm_provider.Error.CapacityExhausted _
      | Llm_provider.Error.HardQuota _
      | Llm_provider.Error.ProviderUnavailable _
      | Llm_provider.Error.ProviderTerminal _
      | Llm_provider.Error.InvalidConfig _
      | Llm_provider.Error.UnknownVariant _) -> false
  | Agent_sdk.Error.Api _ -> false
  | Agent_sdk.Error.Agent _ -> false
  | Agent_sdk.Error.Mcp _ -> false
  | Agent_sdk.Error.Config _ -> false
  | Agent_sdk.Error.Serialization _ -> false
  | Agent_sdk.Error.Io _ -> false
  | Agent_sdk.Error.Orchestration _ -> false
  | Agent_sdk.Error.Internal _ -> false

let is_model_rejected_parse_error (err : Agent_sdk.Error.sdk_error) : bool =
  match err with
  | Agent_sdk.Error.Api (InvalidRequest _ | NetworkError _ | Timeout _
    | Overloaded _ | ServerError _ | RateLimited _ | AuthError _ | NotFound _
    | PaymentRequired _ | ContextOverflow _) ->
      false
  | Agent_sdk.Error.Provider _ -> false
  | Agent_sdk.Error.Agent _ -> false
  | Agent_sdk.Error.Mcp _ -> false
  | Agent_sdk.Error.Config _ -> false
  | Agent_sdk.Error.Serialization _ -> false
  | Agent_sdk.Error.Io _ -> false
  | Agent_sdk.Error.Orchestration _ -> false
  | Agent_sdk.Error.Internal _ -> false

let is_server_rejected_parse_error (err : Agent_sdk.Error.sdk_error) : bool =
  is_provider_rejected_parse_error err || is_model_rejected_parse_error err

(** Receipt I/O failure: the turn body succeeded but the authoritative
    receipt could not be persisted.  See
    [keeper_agent_run.ml::execution_receipt_append_failed]. *)
let is_receipt_lost_error (err : Agent_sdk.Error.sdk_error) : bool =
  match err with
  | Agent_sdk.Error.Internal msg ->
      string_contains_substring ~needle:"execution_receipt_append_failed" msg
  (* Not a receipt I/O failure. *)
  | Agent_sdk.Error.Api _ -> false
  | Agent_sdk.Error.Provider _ -> false
  | Agent_sdk.Error.Agent _ -> false
  | Agent_sdk.Error.Mcp _ -> false
  | Agent_sdk.Error.Config _ -> false
  | Agent_sdk.Error.Serialization _ -> false
  | Agent_sdk.Error.Io _ -> false
  | Agent_sdk.Error.Orchestration _ -> false

let is_provider_timeout_error (err : Agent_sdk.Error.sdk_error) : bool =
  Keeper_provider_runtime_boundary.is_provider_timeout_error err

(* 524 is Cloudflare's "origin responded too slowly" timeout. At keeper
   orchestration level this means the current provider lane is saturated or
   unhealthy enough that rotating/cooling it as backpressure is more useful
   than lumping it into a generic server_error bucket. *)
let is_gateway_backpressure_status status = status = 524

let is_auto_recoverable_runtime_exhausted_error (err : Agent_sdk.Error.sdk_error) : bool =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some
      (Keeper_turn_driver.Runtime_exhausted
         { reason = Keeper_turn_driver.Candidates_filtered_after_cycles; _ }) ->
      true
  | Some
      (Keeper_turn_driver.Runtime_exhausted
         { reason = Keeper_turn_driver.Capacity_exhausted; _ }) ->
      true
  | Some (Keeper_turn_driver.Capacity_backpressure { cooldown_cause; _ }) ->
      (* A pre-dispatch provider-health cooldown block carries the failure that
         armed the cooldown.  Deterministic causes (config/build error, depleted
         balance, structural provider failure) re-fail on the next tick, so they
         must NOT be auto-recoverable: returning [false] makes [counts_toward_crash]
         true so the existing failure-streak policy escalates instead of the
         keeper oscillating (#23438).  Genuine upstream capacity backpressure
         ([None]) and transient causes stay auto-recoverable. *)
      (match cooldown_cause with
       | Some cause ->
         not (Keeper_turn_driver.provider_cooldown_cause_is_deterministic cause)
       | None -> true)
  | Some (Keeper_turn_driver.Runtime_exhausted _) ->
      false
  | Some (Keeper_turn_driver.Accept_rejected _)
  | Some (Keeper_turn_driver.Resumable_cli_session _)
  | Some (Keeper_turn_driver.Admission_queue_rejected _)
  | Some (Keeper_turn_driver.Admission_queue_timeout _)
  | Some (Keeper_turn_driver.Turn_timeout _)
  | Some (Keeper_turn_driver.Provider_timeout _)
  | Some (Keeper_turn_driver.Ambiguous_post_commit _)
  (* RFC-0159 Phase A: opaque internal failures. *)
  | Some (Keeper_turn_driver.Internal_unhandled_exception _)
  | Some (Keeper_turn_driver.Internal_bridge_exception _)
  | Some (Keeper_turn_driver.Internal_contract_rejected _)
  | None ->
      false

let is_resumable_cli_session_error (err : Agent_sdk.Error.sdk_error) : bool =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Resumable_cli_session _) -> true
  | Some (Keeper_turn_driver.Runtime_exhausted _)
  | Some (Keeper_turn_driver.Capacity_backpressure _)
  | Some (Keeper_turn_driver.Accept_rejected _)
  | Some (Keeper_turn_driver.Admission_queue_timeout _)
  | Some (Keeper_turn_driver.Admission_queue_rejected _)
  | Some (Keeper_turn_driver.Turn_timeout _)
  | Some (Keeper_turn_driver.Provider_timeout _)
  | Some (Keeper_turn_driver.Ambiguous_post_commit _)
  (* RFC-0159 Phase A: opaque internal failures. *)
  | Some (Keeper_turn_driver.Internal_unhandled_exception _)
  | Some (Keeper_turn_driver.Internal_bridge_exception _)
  | Some (Keeper_turn_driver.Internal_contract_rejected _)
  | None ->
      false

let is_auto_recoverable_runtime_fail_open_error
    (err : Agent_sdk.Error.sdk_error) : bool =
  Keeper_turn_driver.sdk_error_is_hard_quota err
  || is_resumable_cli_session_error err
  || is_auto_recoverable_runtime_exhausted_error err

let is_accept_no_usable_progress_error (err : Agent_sdk.Error.sdk_error) : bool =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some
      (Keeper_turn_driver.Accept_rejected
         { reason_kind = Some Keeper_turn_driver.Accept_no_usable_progress; _ }) ->
    true
  | Some (Keeper_turn_driver.Accept_rejected _) ->
    false
  | Some
      ( Keeper_turn_driver.Runtime_exhausted _
      | Keeper_turn_driver.Capacity_backpressure _
      | Keeper_turn_driver.Resumable_cli_session _
      | Keeper_turn_driver.Admission_queue_rejected _
      | Keeper_turn_driver.Admission_queue_timeout _
      | Keeper_turn_driver.Turn_timeout _
      | Keeper_turn_driver.Provider_timeout _
      | Keeper_turn_driver.Ambiguous_post_commit _
      | Keeper_turn_driver.Internal_unhandled_exception _
      | Keeper_turn_driver.Internal_bridge_exception _
      | Keeper_turn_driver.Internal_contract_rejected _ )
  | None ->
    false

(* Classification of why a degraded retry is being attempted.  Closed set
   covering both producer paths: [phase_recovery_retry] (7 narrow reasons)
   and [recoverable_runtime_failure_reason] (broader set including raw
   provider API failures).  Wire form is the lowercase string via
   [degraded_retry_reason_to_string]. *)
type degraded_retry_reason =
  | Hard_quota
  | Resumable_cli_session
  | Admission_queue_timeout
  | Provider_timeout
  | Turn_timeout
  | Runtime_candidates_filtered
  | Runtime_exhausted
  | Capacity_backpressure
  | Model_unavailable
  | Rate_limit
  | Server_error
  | Auth_error
  | Read_only_no_progress
  | Empty_no_progress
  | Thinking_only_no_progress

let degraded_retry_reason_to_string = function
  | Hard_quota -> "hard_quota"
  | Resumable_cli_session -> "resumable_cli_session"
  | Admission_queue_timeout -> "admission_queue_timeout"
  | Provider_timeout -> "provider_timeout"
  | Turn_timeout -> "turn_timeout"
  | Runtime_candidates_filtered -> "runtime_candidates_filtered"
  | Runtime_exhausted -> "runtime_exhausted"
  | Capacity_backpressure -> "capacity_backpressure"
  | Model_unavailable ->
    Keeper_runtime_failure_route.rotate_class_label
      Keeper_runtime_failure_route.Model_unavailable
  | Rate_limit -> "rate_limit"
  | Server_error -> "server_error"
  | Auth_error -> "auth_error"
  | Read_only_no_progress -> "read_only_no_progress"
  | Empty_no_progress -> "empty_no_progress"
  | Thinking_only_no_progress -> "thinking_only_no_progress"

let accept_rejection_degraded_retry_reason err =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some internal_error ->
    (match Keeper_turn_driver.accept_no_progress_retry_kind internal_error with
     | Some `Empty_no_progress -> Some Empty_no_progress
     | Some `Read_only_no_progress -> Some Read_only_no_progress
     | Some `Thinking_only_no_progress -> Some Thinking_only_no_progress
     | None -> None)
  | None -> None

let is_recoverable_no_progress_accept_rejection
    (err : Agent_sdk.Error.sdk_error) : bool =
  match accept_rejection_degraded_retry_reason err with
  | Some
      ( Empty_no_progress
      | Read_only_no_progress
      | Thinking_only_no_progress ) ->
    true
  | Some _ | None -> false

let is_read_only_no_progress_accept_rejection
    (err : Agent_sdk.Error.sdk_error) : bool =
  match accept_rejection_degraded_retry_reason err with
  | Some Read_only_no_progress -> true
  | Some _ | None -> false

type degraded_retry =
  { next_runtime : string
  ; fallback_reason : degraded_retry_reason
  }

let is_declared_phase_alias raw phase_name =
  String.equal (String.trim raw) phase_name

let fallback_runtime_for_unavailable_profile
    ~(base_runtime : string)
    ~(effective_runtime : string) : string option =
  let normalized_base =
    String.trim base_runtime
  in
  let normalized_effective =
    String.trim effective_runtime
  in
  if not (String.equal normalized_effective normalized_base)
  then Some normalized_base
  else if
    String.equal normalized_effective (Keeper_config.default_runtime_id ())
    || String.equal normalized_effective (Keeper_config.default_runtime_id ())
  then None
  else Some (Keeper_config.default_runtime_id ())

let degraded_retry_after_recoverable_error
    ~(effective_runtime : string)
    (err : Agent_sdk.Error.sdk_error) : degraded_retry option =
  let normalized_effective =
    String.trim effective_runtime
  in
  let effective_is_declared_phase_buffer =
    is_declared_phase_alias effective_runtime (Keeper_config.default_runtime_id ())
  in
  let effective_is_declared_phase_recovery =
    is_declared_phase_alias
      effective_runtime
      (Keeper_config.default_runtime_id ())
  in
  let phase_recovery_retry fallback_reason =
    Some
      {
        next_runtime = (Keeper_config.default_runtime_id ());
        fallback_reason;
      }
  in
  if effective_is_declared_phase_buffer
     || effective_is_declared_phase_recovery
     || String.equal normalized_effective (Keeper_config.default_runtime_id ())
     || String.equal normalized_effective (Keeper_config.default_runtime_id ())
  then None
  else if Keeper_turn_driver.sdk_error_is_hard_quota err then
    phase_recovery_retry Hard_quota
  else
    match Keeper_turn_driver.classify_masc_internal_error err with
    | Some (Keeper_turn_driver.Resumable_cli_session _) ->
        phase_recovery_retry Resumable_cli_session
    | Some (Keeper_turn_driver.Admission_queue_timeout _) ->
        phase_recovery_retry Admission_queue_timeout
    | Some (Keeper_turn_driver.Provider_timeout _) ->
        phase_recovery_retry Provider_timeout
    | Some (Keeper_turn_driver.Turn_timeout _) ->
        phase_recovery_retry Turn_timeout
    | Some (Keeper_turn_driver.Capacity_backpressure _) ->
        phase_recovery_retry Capacity_backpressure
    | Some
        (Keeper_turn_driver.Runtime_exhausted
           { reason = Keeper_turn_driver.Capacity_exhausted; _ }) ->
        phase_recovery_retry Capacity_backpressure
    | Some
        (Keeper_turn_driver.Runtime_exhausted
           { reason = Keeper_turn_driver.Candidates_filtered_after_cycles; _ }) ->
        phase_recovery_retry Runtime_candidates_filtered
    | Some (Keeper_turn_driver.Accept_rejected _) ->
        (match accept_rejection_degraded_retry_reason err with
         | Some reason -> phase_recovery_retry reason
         | None -> None)
    | Some
        (Keeper_turn_driver.Runtime_exhausted _)
    | Some (Keeper_turn_driver.Admission_queue_rejected _)
    | Some (Keeper_turn_driver.Ambiguous_post_commit _)
    (* RFC-0159 Phase A: opaque internal failures have no
       local-recovery retry mapping. *)
    | Some (Keeper_turn_driver.Internal_unhandled_exception _)
    | Some (Keeper_turn_driver.Internal_bridge_exception _)
    | Some (Keeper_turn_driver.Internal_contract_rejected _)
    | None ->
        None

let recoverable_runtime_failure_reason (err : Agent_sdk.Error.sdk_error) =
  (* RFC-0313 keeps the broader legacy rotation ladder until its W3 flip, but
     model availability already has an authoritative closed route. Consume
     that route here instead of independently matching OAS [NotFound] again. *)
  match Keeper_runtime_failure_route.route_of_error err with
  | Keeper_runtime_failure_route.Rotate_now
      { rotate = Keeper_runtime_failure_route.Model_unavailable } ->
    Some Model_unavailable
  | Keeper_runtime_failure_route.Retry_after_pacing _
  | Keeper_runtime_failure_route.Rotate_now _
  | Keeper_runtime_failure_route.Escalate_judgment _ ->
    if Keeper_turn_driver.sdk_error_is_hard_quota err then
      Some Hard_quota
    else
      match Keeper_turn_driver.classify_masc_internal_error err with
    | Some (Keeper_turn_driver.Resumable_cli_session _) ->
        Some Resumable_cli_session
    | Some (Keeper_turn_driver.Admission_queue_timeout _) ->
        Some Admission_queue_timeout
    | Some (Keeper_turn_driver.Provider_timeout _) ->
        Some Provider_timeout
    | Some (Keeper_turn_driver.Turn_timeout _) ->
        Some Turn_timeout
    | Some (Keeper_turn_driver.Capacity_backpressure _) ->
        Some Capacity_backpressure
    | Some
        (Keeper_turn_driver.Runtime_exhausted
           { reason = Keeper_turn_driver.Capacity_exhausted; _ }) ->
        Some Capacity_backpressure
    | Some
        (Keeper_turn_driver.Runtime_exhausted
           { reason = Keeper_turn_driver.Candidates_filtered_after_cycles; _ }) ->
        Some Runtime_candidates_filtered
    | Some
        (Keeper_turn_driver.Runtime_exhausted _) ->
        (* Generic runtime exhaustion: all candidates failed without a more
           specific reason. Treat as recoverable so declarative
           [fallback_runtime] hints declared in runtime.toml actually
           escalate. Receipt-derived data on 2026-04-25 showed 31/39
           silent turns ended with [(null)] fallback_reason because this
           arm previously returned [None]. Other arms below remain
           non-recoverable to keep the surface conservative. *)
        Some Runtime_exhausted
    | Some (Keeper_turn_driver.Accept_rejected _) ->
        accept_rejection_degraded_retry_reason err
    | Some (Keeper_turn_driver.Admission_queue_rejected _)
    | Some (Keeper_turn_driver.Ambiguous_post_commit _)
    (* RFC-0159 Phase A: typed [Internal_*] variants are not runtime-rotation
       reasons; they expose previously-opaque raw exception payloads.  *)
    | Some (Keeper_turn_driver.Internal_unhandled_exception _)
    | Some (Keeper_turn_driver.Internal_bridge_exception _)
    | Some (Keeper_turn_driver.Internal_contract_rejected _) ->
        None
    | None ->
        (* Status-code-aware runtime rotation: raw provider API errors that are
           not wrapped in a MASC internal error (e.g. single-provider runtimes
           where OAS surfaces the error directly) should still trigger rotation
           when a different runtime may succeed.

           429 rate-limit (non-hard-quota): rotate only to candidates outside
           the throttled runtime's credential pool. The filter lives at the
           candidate boundary below, where runtime/provider credentials are
           available.

           5xx server errors: the provider is unhealthy or overloaded; a
           different runtime may be healthy.

           401/403 auth errors: the credential for this runtime is invalid; a
           different runtime with different credentials may succeed.

           Hard-quota 429s are already handled above by sdk_error_is_hard_quota.
           HTTP 402 PaymentRequired is also handled there via OAS
           Retry.is_hard_quota.
           Soft (non-hard-quota) rate limits intentionally keep [Rate_limit]
           so pool-aware candidate filtering can preserve independent-provider
           failover. *)
        (match err with
         | Agent_sdk.Error.Api (Llm_provider.Retry.RateLimited _) ->
             Some Rate_limit
         | Agent_sdk.Error.Api (Llm_provider.Retry.Overloaded _) ->
             Some Capacity_backpressure
         | Agent_sdk.Error.Api (Llm_provider.Retry.ServerError { status; _ })
           when is_gateway_backpressure_status status ->
             Some Capacity_backpressure
         | Agent_sdk.Error.Api (Llm_provider.Retry.ServerError { status; _ })
           when status >= 500 ->
             Some Server_error
         | Agent_sdk.Error.Api (Llm_provider.Retry.AuthError _) ->
             Some Auth_error
         | Agent_sdk.Error.Provider
             (Llm_provider.Error.RateLimit _) ->
             Some Rate_limit
         | Agent_sdk.Error.Provider (Llm_provider.Error.CapacityExhausted _) ->
             Some Capacity_backpressure
         | Agent_sdk.Error.Provider (Llm_provider.Error.HardQuota _) ->
             Some Hard_quota
         | Agent_sdk.Error.Provider (Llm_provider.Error.ServerError { code; _ })
           when is_gateway_backpressure_status code ->
             Some Capacity_backpressure
         | Agent_sdk.Error.Provider (Llm_provider.Error.ServerError { code; transient; _ })
           when transient || code >= 500 ->
             Some Server_error
         | Agent_sdk.Error.Provider (Llm_provider.Error.ProviderUnavailable _) ->
             Some Server_error
         | Agent_sdk.Error.Provider
             (Llm_provider.Error.AuthError _ | Llm_provider.Error.MissingApiKey _) ->
             Some Auth_error
         | Agent_sdk.Error.Provider
             (Llm_provider.Error.ServerError _
             | Llm_provider.Error.InvalidConfig _
             | Llm_provider.Error.InvalidRequest _
             | Llm_provider.Error.NotFound _
             | Llm_provider.Error.NetworkError _
             | Llm_provider.Error.Timeout _
             | Llm_provider.Error.ParseError _
             | Llm_provider.Error.UnknownVariant _
             | Llm_provider.Error.ProviderTerminal _) ->
             None
         (* Sub-500 server errors and remaining 4xx API errors are not
            classified as recoverable runtime failures. *)
         | Agent_sdk.Error.Api (Llm_provider.Retry.ServerError _)
         | Agent_sdk.Error.Api (Llm_provider.Retry.PaymentRequired _)
         | Agent_sdk.Error.Api (Llm_provider.Retry.InvalidRequest _)
         | Agent_sdk.Error.Api (Llm_provider.Retry.NotFound _)
         | Agent_sdk.Error.Api (Llm_provider.Retry.ContextOverflow _)
         | Agent_sdk.Error.Api (Llm_provider.Retry.NetworkError _)
         | Agent_sdk.Error.Api (Llm_provider.Retry.Timeout _) -> None
         (* Non-API error families have no rotation reason here: structured
            MASC internal errors are handled by [classify_masc_internal_error]
            above; agent / mcp / config / etc. are not provider-level rotations. *)
         | Agent_sdk.Error.Agent _
         | Agent_sdk.Error.Mcp _
         | Agent_sdk.Error.Config _
         | Agent_sdk.Error.Serialization _
         | Agent_sdk.Error.Io _
         | Agent_sdk.Error.Orchestration _
         | Agent_sdk.Error.Internal _ -> None)

let normalized_runtime_id ~catalog_names name =
  let trimmed = String.trim name in
  if List.exists (String.equal trimmed) catalog_names then trimmed
  else if
    String.equal trimmed (Keeper_config.default_runtime_id ())
    || String.equal trimmed (Keeper_config.default_runtime_id ())
    || String.equal trimmed (Keeper_config.default_runtime_id ())
  then trimmed
  else String.trim trimmed

let runtime_catalog_names () =
  match Runtime.get_runtime_ids () with
  | [] -> [ Keeper_config.default_runtime_id () ]
  | names -> names
;;

let default_degraded_rotation_candidates
    ~catalog_names
    ~(fallback_reason : degraded_retry_reason option)
    ~(base_runtime : string) =
  let normalized_base = normalized_runtime_id ~catalog_names base_runtime in
  let default_runtime =
    normalized_runtime_id ~catalog_names (Keeper_config.default_runtime_id ())
  in
  let phase_recovery_runtime =
    normalized_runtime_id ~catalog_names
      (Runtime.get_default_runtime_id ())
  in
  let default_candidates = [ normalized_base; default_runtime; phase_recovery_runtime ] in
  let catalog_runtimes =
    Runtime.get_runtimes ()
    |> List.map (fun (runtime : Runtime.t) ->
           normalized_runtime_id ~catalog_names runtime.id)
  in
  let candidates_with_catalog =
    dedupe_keep_order (default_candidates @ catalog_runtimes)
  in
  match fallback_reason with
  | Some (Read_only_no_progress | Empty_no_progress | Thinking_only_no_progress) ->
    let tool_capable =
      Runtime.get_runtimes ()
      |> List.filter (fun (runtime : Runtime.t) -> runtime.model.tools_support)
      |> List.map (fun (runtime : Runtime.t) ->
             normalized_runtime_id ~catalog_names runtime.id)
    in
    dedupe_keep_order (default_candidates @ tool_capable)
  | Some
      ( Capacity_backpressure
      | Model_unavailable
      | Provider_timeout
      | Server_error
      | Auth_error
      | Runtime_exhausted
      | Runtime_candidates_filtered
      | Turn_timeout
      | Resumable_cli_session
      | Admission_queue_timeout ) ->
    (* Phase B-1: include the full runtime catalog so transient infrastructure
       failures (notably capacity_backpressure) can fail over to a healthy
       runtime outside the narrow [base; default; phase_recovery] set.
       Without this, two runtimes in cooldown had nowhere to go (#23373,
       incidents 2026-05-21 / 2026-07-06). Credential-pool filtering is
       applied downstream by [degraded_rotation_after_recoverable_error] via
       [filter_quota_pool_rotation_candidates]. *)
    candidates_with_catalog
  | Some (Hard_quota | Rate_limit)
  | None ->
    default_candidates

let normalize_rotation_candidates ~catalog_names candidates =
  candidates
  |> List.filter_map (fun candidate ->
         let trimmed = String.trim candidate in
         if String.equal trimmed "" then None
         else Some (normalized_runtime_id ~catalog_names trimmed))
  |> dedupe_keep_order

let degraded_rotation_candidates
    ~catalog_names
    ~(fallback_reason : degraded_retry_reason)
    ~(fallback_hint : string option)
    ~(base_runtime : string)
    ~(effective_runtime : string) =
  let normalized_effective =
    normalized_runtime_id ~catalog_names effective_runtime
  in
  let raw_candidates =
    default_degraded_rotation_candidates
      ~catalog_names
      ~fallback_reason:(Some fallback_reason)
      ~base_runtime
  in
  let fallback_hint_candidate =
    match fallback_hint with
    | None -> None
    | Some hint ->
        let trimmed = String.trim hint in
        if String.equal trimmed "" then None
        else Some (normalized_runtime_id ~catalog_names trimmed)
  in
  let candidates =
    match fallback_hint_candidate with
    | None -> raw_candidates
    | Some hint -> dedupe_keep_order (hint :: raw_candidates)
  in
  candidates
  |> List.filter (fun candidate ->
         not (String.equal candidate normalized_effective))

let filter_quota_pool_rotation_candidates
      ~credential_pool_of_runtime_id
      ~effective_runtime
      candidates
  =
  match credential_pool_of_runtime_id effective_runtime with
  | None -> candidates
  | Some effective_pool ->
    List.filter
      (fun candidate ->
         match credential_pool_of_runtime_id candidate with
         | None -> true
         | Some candidate_pool -> not (String.equal candidate_pool effective_pool))
      candidates

(** [true] when the error is a completion contract violation.
    Contract violations should cap rotation because retrying the same
    or different runtime will not satisfy the contract. Non-contract
    errors (provider timeout, rate limit, server error) are transient
    and should allow cycling through candidates again. *)
let is_completion_contract_violation (err : Agent_sdk.Error.sdk_error) : bool =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Accept_rejected _) ->
    not (is_recoverable_no_progress_accept_rejection err)
  | Some
      ( Keeper_turn_driver.Runtime_exhausted _
      | Keeper_turn_driver.Capacity_backpressure _
      | Keeper_turn_driver.Resumable_cli_session _
      | Keeper_turn_driver.Admission_queue_timeout _
      | Keeper_turn_driver.Admission_queue_rejected _
      | Keeper_turn_driver.Turn_timeout _
      | Keeper_turn_driver.Provider_timeout _
      | Keeper_turn_driver.Ambiguous_post_commit _
      | Keeper_turn_driver.Internal_unhandled_exception _
      | Keeper_turn_driver.Internal_bridge_exception _
      | Keeper_turn_driver.Internal_contract_rejected _ )
  | None ->
    false

let degraded_reason_allows_candidate_cycle = function
  | Hard_quota
  | Rate_limit
  (* Capacity_backpressure: provider retry_after is minutes-long, so cycling
     the same candidate pool at the turn retry cadence just hammers the
     provider and loops forever (incidents 2026-05-21, 2026-07-06, #23373).
     Cap rotation here; the keeper pauses after candidates are exhausted and
     retries on a later turn once the provider actually recovers. *)
  | Capacity_backpressure
  | Model_unavailable
  | Read_only_no_progress
  | Empty_no_progress
  | Thinking_only_no_progress -> false
  | Resumable_cli_session
  | Admission_queue_timeout
  | Provider_timeout
  | Turn_timeout
  | Runtime_candidates_filtered
  | Runtime_exhausted
  | Server_error
  | Auth_error -> true

let degraded_rotation_after_recoverable_error
      ?(credential_pool_of_runtime_id = fun _ -> None)
      ?fallback_hint
      ~(pacing_enforced : bool)
      ~(base_runtime : string)
      ~(effective_runtime : string)
    ~(attempted_runtimes : string list)
    (err : Agent_sdk.Error.sdk_error) : degraded_retry option =
  match recoverable_runtime_failure_reason err with
  | None -> None
  | Some fallback_reason ->
      (* Load the live catalog once at the degraded-rotation boundary and pass
         the snapshot through normalization/filter helpers.  This preserves
         concrete profile names without adding per-candidate catalog I/O. *)
      let catalog_names = runtime_catalog_names () in
      let attempted =
        attempted_runtimes
        |> List.map (normalized_runtime_id ~catalog_names)
        |> dedupe_keep_order
      in
      let candidates =
        degraded_rotation_candidates
          ~catalog_names
          ~fallback_reason
          ~fallback_hint
          ~base_runtime ~effective_runtime
      in
      let candidates =
        match fallback_reason with
        | Hard_quota
        | Rate_limit ->
          filter_quota_pool_rotation_candidates
            ~credential_pool_of_runtime_id
            ~effective_runtime
            candidates
        | Read_only_no_progress
        | Empty_no_progress
        | Thinking_only_no_progress
        | Resumable_cli_session
        | Admission_queue_timeout
        | Provider_timeout
        | Turn_timeout
        | Runtime_candidates_filtered
        | Runtime_exhausted
        | Capacity_backpressure
        | Model_unavailable
        | Server_error
        | Auth_error -> candidates
      in
      let untried =
        List.find_opt
          (fun candidate ->
             not (List.exists (String.equal candidate) attempted))
          candidates
      in
      (match untried with
       | Some next_runtime ->
         Some { next_runtime; fallback_reason }
       | None
         when (not (is_completion_contract_violation err))
              && (pacing_enforced
                  || degraded_reason_allows_candidate_cycle fallback_reason) ->
         (* Non-contract transient infrastructure errors (provider timeout,
            server error, capacity backpressure) may succeed on a later
            candidate pass. Quota/rate-limit classes cap after all candidates:
            retrying the same credential pool just amplifies an account-scoped
            limit. #19930

            RFC-0313 W3: under enforced pacing the class cap is bypassed —
            in-turn cycling stays bounded by the turn cycle budget
            (Candidates_filtered_after_cycles) and cross-turn retries are
            spaced by revisit pacing, which is what the cap approximated. *)
         (match candidates with
          | [] -> None
          | first_candidate :: _ ->
            Some { next_runtime = first_candidate; fallback_reason })
       | None ->
         (* Contract violation, or (shadow mode) quota/rate-limit exhaustion:
            cap rotation. *)
         None)

(** [true] when a structured error indicates context overflow. *)
let is_context_overflow (err : Agent_sdk.Error.sdk_error) : bool =
  match err with
  | Agent_sdk.Error.Api (ContextOverflow _) -> true
  (* Other API error variants do not indicate context overflow. *)
  | Agent_sdk.Error.Api (RateLimited _)
  | Agent_sdk.Error.Api (Overloaded _)
  | Agent_sdk.Error.Api (ServerError _)
  | Agent_sdk.Error.Api (AuthError _)
  | Agent_sdk.Error.Api (PaymentRequired _)
  | Agent_sdk.Error.Api (InvalidRequest _)
  | Agent_sdk.Error.Api (NotFound _)
  | Agent_sdk.Error.Api (NetworkError _)
  | Agent_sdk.Error.Api (Timeout _) -> false
  | Agent_sdk.Error.Provider _ -> false
  (* Other agent error variants. *)
  | Agent_sdk.Error.Agent (MaxTurnsExceeded _)
  | Agent_sdk.Error.Agent (AgentExecutionTimeout _)
  | Agent_sdk.Error.Agent (AgentExecutionIdleTimeout _)
  | Agent_sdk.Error.Agent (UnrecognizedStopReason _)
  | Agent_sdk.Error.Agent (IdleDetected _)
  | Agent_sdk.Error.Agent (GuardrailViolation _)
  | Agent_sdk.Error.Agent (TripwireViolation _)
  | Agent_sdk.Error.Agent (ExitConditionMet _) -> false
  | Agent_sdk.Error.Agent (InputRequired _) -> false
  (* Non-API / non-Agent error families. *)
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.Internal _ -> false

let is_auto_recoverable_turn_error (err : Agent_sdk.Error.sdk_error) : bool =
  is_transient_network_error err
  || is_server_rejected_parse_error err
  || is_auto_recoverable_runtime_exhausted_error err
  (* Context overflow is handled explicitly by
     [Keeper_turn_runtime_budget.pause_keeper_for_overflow] at the point of
     detection (Overflowed/Compacting FSM retry-exhausted path, auto-resume
     with backoff) rather than by accumulating turn_consecutive_failures
     toward a hard crash — counting it here too would double-penalize an
     event that already has its own graceful pause. *)
  || is_context_overflow err

let should_warn_keeper_cycle_failed (err : Agent_sdk.Error.sdk_error) : bool =
  if Keeper_provider_runtime_boundary.is_provider_timeout_error err
  then true
  else
    match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Capacity_backpressure _) -> true
  | Some (Keeper_turn_driver.Runtime_exhausted _)
  | Some (Keeper_turn_driver.Resumable_cli_session _)
  | Some (Keeper_turn_driver.Accept_rejected _)
  | Some (Keeper_turn_driver.Admission_queue_timeout _)
  | Some (Keeper_turn_driver.Admission_queue_rejected _)
  | Some (Keeper_turn_driver.Provider_timeout _)
  | Some (Keeper_turn_driver.Turn_timeout _)
  | Some (Keeper_turn_driver.Ambiguous_post_commit _)
  (* RFC-0159 Phase A: opaque internal failures should not trigger the
     keeper-cycle-failed WARN by themselves; the surrounding handler
     already logs the exception detail. *)
  | Some (Keeper_turn_driver.Internal_unhandled_exception _)
  | Some (Keeper_turn_driver.Internal_bridge_exception _)
  | Some (Keeper_turn_driver.Internal_contract_rejected _)
  | None ->
    false


include Keeper_error_classify_post_commit

(** Max transient retries (excluding the initial attempt).  Total attempts
    = 1 initial + max_transient_retries.  OAS internal retry is 3 per
    provider; this outer retry covers cases where all providers fail
    transiently (e.g. TCP keepalive expiry across all backends).

    Runtime-configurable via [Env_config_keeper.KeeperRetryBackoff]. *)
let max_transient_retries () =
  Env_config_keeper.KeeperRetryBackoff.max_transient_retries ()

(** Exponential backoff delay for transient retry [attempt] (1-indexed).
    Delegates to [Env_config_keeper.KeeperRetryBackoff]. *)
let transient_backoff_sec (attempt : int) : float =
  Env_config_keeper.KeeperRetryBackoff.transient_backoff_sec attempt

(* [is_context_overflow] now lives earlier in this file, above
   [is_auto_recoverable_turn_error], since that predicate depends on it. *)

(** Extract the [InputRequired] payload from an [sdk_error], if any.
    Typed companion to {!is_input_required_error}; callers that need
    the [input_required] record use this option-returning function so
    a [match ... | _ -> assert false] tail is no longer required. *)
let extract_input_required (err : Agent_sdk.Error.sdk_error)
  : Agent_sdk.Error.input_required option
  =
  match err with
  | Agent_sdk.Error.Agent (Agent_sdk.Error.InputRequired ir) -> Some ir
  | _ -> None
;;

(** [true] when the error is an OAS [InputRequired] — the agent paused
    to request human input.  Not a failure; a special stop condition. *)
let is_input_required_error (err : Agent_sdk.Error.sdk_error) : bool =
  match err with
  | Agent_sdk.Error.Agent (Agent_sdk.Error.InputRequired _) -> true
  | Agent_sdk.Error.Agent (MaxTurnsExceeded _)
  | Agent_sdk.Error.Agent (AgentExecutionTimeout _)
  | Agent_sdk.Error.Agent (AgentExecutionIdleTimeout _)
  | Agent_sdk.Error.Agent (UnrecognizedStopReason _)
  | Agent_sdk.Error.Agent (IdleDetected _)
  | Agent_sdk.Error.Agent (GuardrailViolation _)
  | Agent_sdk.Error.Agent (TripwireViolation _)
  | Agent_sdk.Error.Agent (ExitConditionMet _) -> false
  | Agent_sdk.Error.Api _
  | Agent_sdk.Error.Provider _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.Internal _ -> false

(** [true] when an error represents terminal runtime exhaustion. Accept
    rejection is an accept-contract result; no-progress accept rejection is
    classified separately so it does not masquerade as all-runtimes-exhausted. *)
let is_runtime_exhausted_error (err : Agent_sdk.Error.sdk_error) : bool =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Runtime_exhausted _)
  | Some (Keeper_turn_driver.Resumable_cli_session _) -> true
  | Some (Keeper_turn_driver.Capacity_backpressure _)
  | Some (Keeper_turn_driver.Accept_rejected _)
  | Some (Keeper_turn_driver.Admission_queue_timeout _)
  | Some (Keeper_turn_driver.Admission_queue_rejected _)
  | Some (Keeper_turn_driver.Provider_timeout _)
  | Some (Keeper_turn_driver.Turn_timeout _)
  | Some (Keeper_turn_driver.Ambiguous_post_commit _)
  (* RFC-0159 Phase A: opaque internal failures are not runtime exhaustion. *)
  | Some (Keeper_turn_driver.Internal_unhandled_exception _)
  | Some (Keeper_turn_driver.Internal_bridge_exception _)
  | Some (Keeper_turn_driver.Internal_contract_rejected _) -> false
  | None -> false
