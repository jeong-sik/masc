(** Keeper_error_classify — Error classification
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
  | Transient_rate_limit
  | Transient_capacity
  | Non_transient
  | Unclassified

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
      | Keeper_turn_driver.Internal_bridge_exception _
      | Keeper_turn_driver.Internal_contract_rejected _
      | Keeper_turn_driver.Receipt_persistence_failed _ )
  | None -> false

(** Classify an [sdk_error] into a static [error_classification] variant.
    Replaces the individual heuristic predicate functions with a single
    exhaustive match. *)
let classify_error (err : Agent_sdk.Error.sdk_error) : error_classification =
  if is_transient_internal_runner_error err
  then Transient_internal_runner
  else match err with
  | Agent_sdk.Error.Api (NetworkError _) -> Transient_network
  | Agent_sdk.Error.Api (Timeout _) -> Transient_network
  | Agent_sdk.Error.Api (Overloaded _) -> Transient_capacity
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
  | Agent_sdk.Error.Provider (Llm_provider.Error.Timeout _) -> Transient_network
  | Agent_sdk.Error.Provider (Llm_provider.Error.ServerError { transient; _ }) ->
      if transient then Transient_network else Non_transient
  | Agent_sdk.Error.Provider (Llm_provider.Error.RateLimit _) -> Transient_rate_limit
  | Agent_sdk.Error.Provider
      (Llm_provider.Error.AuthError _ | Llm_provider.Error.AuthorizationError _) ->
      Non_transient
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
    | AuthorizationError _
    | NotFound _ | PaymentRequired _ | ContextOverflow _) -> Non_transient
  | Agent_sdk.Error.Agent (HookExecutionFailed _) -> Non_transient
  | Agent_sdk.Error.Agent
      ( UnrecognizedStopReason _
      | GuardrailViolation _
      | TripwireViolation _
      | InputRequired _ )
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _ | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _ | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.Internal _ -> Unclassified

(** {1 Typed retry classification} *)

let is_transient_network_error (err : Agent_sdk.Error.sdk_error) : bool =
  if is_transient_internal_runner_error err
  then true
  else match err with
  | Agent_sdk.Error.Api (NetworkError _) -> true
  | Agent_sdk.Error.Api (Timeout _) -> true
  | Agent_sdk.Error.Provider (Llm_provider.Error.NetworkError
      { kind = Llm_provider.Http_client.Tls_error
             | Llm_provider.Http_client.Local_resource_exhaustion; _ }) ->
      false
  | Agent_sdk.Error.Provider (Llm_provider.Error.NetworkError _) -> true
  | Agent_sdk.Error.Provider (Llm_provider.Error.Timeout _) -> true
  | Agent_sdk.Error.Api (Overloaded _) -> true
  | Agent_sdk.Error.Provider (Llm_provider.Error.ServerError { transient; _ }) ->
      transient
  (* Non-transient API errors. *)
  | Agent_sdk.Error.Api (ServerError _)
  | Agent_sdk.Error.Api (RateLimited _)
  | Agent_sdk.Error.Api (AuthError _)
  | Agent_sdk.Error.Api (AuthorizationError _)
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

    These errors may recur with the same payload, so they are not eligible
    for same-turn retry. The keeper's next cycle remains available, but a
    committed mutation is never exempted from explicit partial-commit
    handling based on the tool's product identity.

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
      | Llm_provider.Error.AuthError _
      | Llm_provider.Error.AuthorizationError _
      | Llm_provider.Error.MissingApiKey _
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

(** 0-byte empty completion: the provider ended the turn with a modeled,
    non-overflow stop_reason but returned no thinking, text, or tool calls
    (a broken backend model answering with an empty assistant turn).  OAS
    surfaces exactly two shapes for this condition
    (oas [Retry.verdict_of_empty_completion]):

    - [Provider (ProviderUnavailable {detail})] with [detail] starting
      ["empty completion (stop_reason="] — a recognized non-overflow
      stop_reason (e.g. [end_turn]) on an empty assistant turn, routed to
      provider-unavailability handling upstream;
    - [Provider (ParseError {detail})] whose detail embeds the marker
      ["empty completion (no thinking, text, or tool calls"]
      (defensive: see the branch comment in [is_empty_completion_error] —
      no production producer of this shape exists at the pinned SDK).

    Deliberately excluded:

    - [Api (InvalidRequest _)] — OAS flattens only the unmodeled-stop_reason
      and the context-overflow empty completions into [InvalidRequest].  The
      first is intentionally non-retryable (oas
      provider_failure_attribution.ml: retrying replays the identical prompt
      and never terminates); the second replays the same oversized prompt.
      Neither is recoverable by retry or failover, so no [InvalidRequest]
      message text is matched here — free-form provider bodies are not a
      classification source (see [is_provider_rejected_parse_error]).
    - ["Context overflow: empty completion"] — a context-overflow diagnostic,
      already classified by [is_context_overflow] on the typed path. *)
let is_empty_completion_error (err : Agent_sdk.Error.sdk_error) : bool =
  match err with
  | Agent_sdk.Error.Provider
      (Llm_provider.Error.ProviderUnavailable { detail; _ }) ->
      String.starts_with ~prefix:"empty completion (stop_reason=" detail
  | Agent_sdk.Error.Provider (Llm_provider.Error.ParseError { detail }) ->
      (* Defensive: no production producer at pinned SDK 5851df2e.  The
         marker is rendered only by backend_openai_parse.ml
         [parse_error_to_string], whose callers are all test-only; production
         empty completions route via [Http_client.empty_completion_error] into
         [ProviderUnavailable]/[InvalidRequest], and production [ParseError]
         details come from sse/glm/image_generation/speech_generation parse
         failures.  Kept as a bounded guard (exemption budget caps the blast
         radius) in case a future SDK promotes this shape to [ParseError]. *)
      String_util.contains_substring detail "empty completion (no thinking"
  | Agent_sdk.Error.Provider _ -> false
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
    | Overloaded _ | ServerError _ | RateLimited _ | AuthError _
    | AuthorizationError _ | NotFound _ | PaymentRequired _ | ContextOverflow _) ->
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
    receipt could not be persisted. The producer carries a typed MASC error;
    free-form error prose is never used as a behavioral discriminator. *)
let is_receipt_lost_error (err : Agent_sdk.Error.sdk_error) : bool =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Receipt_persistence_failed _) -> true
  | Some _ | None -> false

let is_provider_timeout_error (err : Agent_sdk.Error.sdk_error) : bool =
  Keeper_provider_runtime_boundary.is_provider_timeout_error err

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
  | Some (Keeper_turn_driver.Capacity_backpressure _) ->
      (* Legacy [cooldown_cause] values are diagnostic-only. A decoded receipt
         from the retired pre-dispatch gate must not regain lifecycle authority. *)
      true
  | Some (Keeper_turn_driver.Runtime_exhausted _) ->
      false
  | Some (Keeper_turn_driver.Accept_rejected _)
  | Some (Keeper_turn_driver.Resumable_cli_session _)
  (* RFC-0159 Phase A: opaque internal failures. *)
  | Some (Keeper_turn_driver.Internal_unhandled_exception _)
  | Some (Keeper_turn_driver.Internal_bridge_exception _)
  | Some (Keeper_turn_driver.Internal_contract_rejected _)
  | Some (Keeper_turn_driver.Receipt_persistence_failed _)
  | None ->
      false

let is_resumable_cli_session_error (err : Agent_sdk.Error.sdk_error) : bool =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Resumable_cli_session _) -> true
  | Some (Keeper_turn_driver.Runtime_exhausted _)
  | Some (Keeper_turn_driver.Capacity_backpressure _)
  | Some (Keeper_turn_driver.Accept_rejected _)
  (* RFC-0159 Phase A: opaque internal failures. *)
  | Some (Keeper_turn_driver.Internal_unhandled_exception _)
  | Some (Keeper_turn_driver.Internal_bridge_exception _)
  | Some (Keeper_turn_driver.Internal_contract_rejected _)
  | Some (Keeper_turn_driver.Receipt_persistence_failed _)
  | None ->
      false

let is_auto_recoverable_runtime_fail_open_error
    (err : Agent_sdk.Error.sdk_error) : bool =
  Keeper_runtime_failure_route.sdk_error_is_hard_quota err
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
      | Keeper_turn_driver.Internal_unhandled_exception _
      | Keeper_turn_driver.Internal_bridge_exception _
      | Keeper_turn_driver.Internal_contract_rejected _
      | Keeper_turn_driver.Receipt_persistence_failed _ )
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
  | Runtime_candidates_filtered
  | Runtime_exhausted
  | Capacity_backpressure
  | Rate_limit
  | Server_error
  | Auth_error
  | Empty_no_progress
  | Thinking_only_no_progress

let degraded_retry_reason_to_string = function
  | Hard_quota -> "hard_quota"
  | Resumable_cli_session -> "resumable_cli_session"
  | Runtime_candidates_filtered -> "runtime_candidates_filtered"
  | Runtime_exhausted -> "runtime_exhausted"
  | Capacity_backpressure -> "capacity_backpressure"
  | Rate_limit -> "rate_limit"
  | Server_error -> "server_error"
  | Auth_error -> "auth_error"
  | Empty_no_progress -> "empty_no_progress"
  | Thinking_only_no_progress -> "thinking_only_no_progress"

let accept_rejection_degraded_retry_reason err =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some internal_error ->
    (match Keeper_turn_driver.accept_no_progress_retry_kind internal_error with
     | Some `Empty_no_progress -> Some Empty_no_progress
     | Some `Thinking_only_no_progress -> Some Thinking_only_no_progress
     | None -> None)
  | None -> None

let is_recoverable_no_progress_accept_rejection
    (err : Agent_sdk.Error.sdk_error) : bool =
  match accept_rejection_degraded_retry_reason err with
  | Some (Empty_no_progress | Thinking_only_no_progress) ->
    true
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
  else if Keeper_runtime_failure_route.sdk_error_is_hard_quota err then
    phase_recovery_retry Hard_quota
  else
    match Keeper_turn_driver.classify_masc_internal_error err with
    | Some (Keeper_turn_driver.Resumable_cli_session _) ->
        phase_recovery_retry Resumable_cli_session
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
    (* RFC-0159 Phase A: opaque internal failures have no
       local-recovery retry mapping. *)
    | Some (Keeper_turn_driver.Internal_unhandled_exception _)
    | Some (Keeper_turn_driver.Internal_bridge_exception _)
    | Some (Keeper_turn_driver.Internal_contract_rejected _)
    | Some (Keeper_turn_driver.Receipt_persistence_failed _)
    | None ->
        None

let recoverable_runtime_failure_reason (err : Agent_sdk.Error.sdk_error) =
  if Keeper_runtime_failure_route.sdk_error_is_hard_quota err then
    Some Hard_quota
  else
    match Keeper_turn_driver.classify_masc_internal_error err with
    | Some (Keeper_turn_driver.Resumable_cli_session _) ->
        Some Resumable_cli_session
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
    (* RFC-0159 Phase A: typed [Internal_*] variants are not runtime-rotation
       reasons; they expose previously-opaque raw exception payloads.  *)
    | Some (Keeper_turn_driver.Internal_unhandled_exception _)
    | Some (Keeper_turn_driver.Internal_bridge_exception _)
    | Some (Keeper_turn_driver.Internal_contract_rejected _)
    | Some (Keeper_turn_driver.Receipt_persistence_failed _) ->
        None
    | None ->
        (* Typed runtime rotation: raw provider API errors that are
           not wrapped in a MASC internal error (e.g. single-provider runtimes
           where OAS surfaces the error directly) should still trigger rotation
           when a different runtime may succeed.

           429 rate-limit (non-hard-quota): rotate through explicitly declared
           candidates. The error type does not carry model/account/provider
           scope, so this boundary must not infer a broader blocked set.

           [ServerError]: the provider is unhealthy or overloaded; a
           different runtime may be healthy.

           401/403 auth errors: the credential for this runtime is invalid; a
           different runtime with different credentials may succeed.

           [PaymentRequired] and provider [HardQuota] are handled above by
           [sdk_error_is_hard_quota]. Rate limits intentionally keep [Rate_limit]
           so declared runtime fallback remains available. *)
        (match err with
         | Agent_sdk.Error.Api (Llm_provider.Retry.RateLimited _) ->
             Some Rate_limit
         | Agent_sdk.Error.Api (Llm_provider.Retry.Overloaded _) ->
             Some Capacity_backpressure
         | Agent_sdk.Error.Api (Llm_provider.Retry.ServerError _) ->
             Some Server_error
         | Agent_sdk.Error.Api
             ( Llm_provider.Retry.AuthError _
             | Llm_provider.Retry.AuthorizationError _ ) ->
             Some Auth_error
         | Agent_sdk.Error.Provider
             (Llm_provider.Error.RateLimit _) ->
             Some Rate_limit
         | Agent_sdk.Error.Provider (Llm_provider.Error.CapacityExhausted _) ->
             Some Capacity_backpressure
         | Agent_sdk.Error.Provider (Llm_provider.Error.HardQuota _) ->
             Some Hard_quota
         | Agent_sdk.Error.Provider
             (Llm_provider.Error.ServerError { transient = true; _ }) ->
             Some Server_error
         | Agent_sdk.Error.Provider (Llm_provider.Error.ProviderUnavailable _) ->
             Some Server_error
         | Agent_sdk.Error.Provider
             ( Llm_provider.Error.AuthError _
             | Llm_provider.Error.AuthorizationError _
             | Llm_provider.Error.MissingApiKey _ ) ->
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
  | Some (Empty_no_progress | Thinking_only_no_progress) ->
    let tool_capable =
      Runtime.get_runtimes ()
      |> List.filter (fun (runtime : Runtime.t) -> runtime.model.tools_support)
      |> List.map (fun (runtime : Runtime.t) ->
             normalized_runtime_id ~catalog_names runtime.id)
    in
    dedupe_keep_order (default_candidates @ tool_capable)
  | Some
      ( Capacity_backpressure
      | Server_error
      | Auth_error
      | Runtime_exhausted
      | Runtime_candidates_filtered
      | Resumable_cli_session ) ->
    (* Phase B-1: include the full runtime catalog so transient infrastructure
       failures (notably capacity_backpressure) can fail over to a healthy
       runtime outside the narrow [base; default; phase_recovery] set.
       Without this, two unavailable runtimes had nowhere to go (#23373,
       incidents 2026-05-21 / 2026-07-06). *)
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

let degraded_rotation_after_recoverable_error
      ?fallback_hint
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
      let untried =
        List.find_opt
          (fun candidate ->
             not (List.exists (String.equal candidate) attempted))
          candidates
      in
      (match untried with
       | Some next_runtime ->
         Some { next_runtime; fallback_reason }
       | None ->
         (* One typed candidate pass is complete. A later Keeper turn may make
            a fresh attempt; this boundary never invents a timed retry cycle. *)
         None)

(** [true] when a structured error indicates context overflow. *)
let is_invalid_request_error (err : Agent_sdk.Error.sdk_error) : bool =
  match err with
  | Agent_sdk.Error.Api (InvalidRequest _) -> true
  | _ ->
    let msg = Agent_sdk.Error.to_string err in
    let has_prefix str prefix =
      let len_p = String.length prefix in
      String.length str >= len_p && String.sub str 0 len_p = prefix
    in
    has_prefix msg "Invalid request"
    || has_prefix msg "Bad Request"
    || has_prefix msg "oas-ollama_cloud" && String.contains msg '4'

(** [true] when a structured error indicates context overflow. *)
let is_context_overflow (err : Agent_sdk.Error.sdk_error) : bool =
  match err with
  | Agent_sdk.Error.Api (ContextOverflow _) -> true
  | Agent_sdk.Error.Agent (UnrecognizedStopReason { reason = "model_context_window_exceeded"; _ }) -> true
  | _ ->
    let msg = Agent_sdk.Error.to_string err in
    (match String.split_on_char ':' msg with
     | "Context overflow" :: _ -> true
     | _ ->
       let contains_substring str sub =
         let len_s = String.length str in
         let len_sub = String.length sub in
         if len_sub > len_s then false
         else
           let found = ref false in
           for i = 0 to len_s - len_sub do
             if not !found && String.sub str i len_sub = sub then found := true
           done;
           !found
       in
       contains_substring msg "model_context_window_exceeded"
       || contains_substring msg "Context overflow")

(* Invariant for this predicate: every class listed here is exempted from the
   crash threshold ([Keeper_unified_turn_failure.record_failure_observation]
   skips [increment_turn_failures] entirely), so each class must carry its own
   compensating accounting. Without one, "not counted toward crash" means the
   keeper retries the same failure forever with [consecutive] pinned at 0.

   - transient network / runtime-exhausted: bounded by the runtime rotation and
     exhaustion paths.
   - context overflow: accounted at the point of detection by
     [Keeper_turn_runtime_budget.record_overflow_failure], and its in-lane
     compaction retries are bounded (#25536).
   - 0-byte empty completion: bounded by
     [Keeper_unified_turn_failure]'s per-keeper exemption budget — after
     [empty_completion_exemption_budget] consecutive exempted empty
     completions the failure counts toward the crash threshold again, and a
     successful turn resets the budget.  Only the modeled, non-overflow
     shapes are exempt (see [is_empty_completion_error]); the unmodeled
     stop_reason shape that OAS intentionally reports as non-retryable
     [InvalidRequest] is NOT exempt and keeps counting toward crash.

   Provider parse rejections used to be listed here and had no such accounting.
   A provider that keeps emitting a malformed stream (for example a tool_call
   delta with a blank id, which the OAS SSE parser rejects) produced an
   unbounded retry loop: 923 rejections across five keepers in 1h41m on
   2026-07-21, each attempt costing up to 70s, with no escalation because the
   counter never advanced. They are no longer exempt, so the ordinary
   consecutive-failure threshold bounds them; an isolated malformed response
   still costs nothing, because a later success resets the counter. *)
let is_auto_recoverable_turn_error (err : Agent_sdk.Error.sdk_error) : bool =
  is_transient_network_error err
  || is_auto_recoverable_runtime_exhausted_error err
  || is_context_overflow err
  || is_empty_completion_error err
  || is_invalid_request_error err

let should_warn_keeper_cycle_failed (err : Agent_sdk.Error.sdk_error) : bool =
  if Keeper_provider_runtime_boundary.is_provider_timeout_error err
  then true
  else
    match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Capacity_backpressure _) -> true
  | Some (Keeper_turn_driver.Runtime_exhausted _)
  | Some (Keeper_turn_driver.Resumable_cli_session _)
  | Some (Keeper_turn_driver.Accept_rejected _)
  (* RFC-0159 Phase A: opaque internal failures should not trigger the
     keeper-cycle-failed WARN by themselves; the surrounding handler
     already logs the exception detail. *)
  | Some (Keeper_turn_driver.Internal_unhandled_exception _)
  | Some (Keeper_turn_driver.Internal_bridge_exception _)
  | Some (Keeper_turn_driver.Internal_contract_rejected _)
  | Some (Keeper_turn_driver.Receipt_persistence_failed _)
  | None ->
    false

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
  | Agent_sdk.Error.Agent (UnrecognizedStopReason _)
  | Agent_sdk.Error.Agent (HookExecutionFailed _)
  | Agent_sdk.Error.Agent (GuardrailViolation _)
  | Agent_sdk.Error.Agent (TripwireViolation _) -> false
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
  (* RFC-0159 Phase A: opaque internal failures are not runtime exhaustion. *)
  | Some (Keeper_turn_driver.Internal_unhandled_exception _)
  | Some (Keeper_turn_driver.Internal_bridge_exception _)
  | Some (Keeper_turn_driver.Internal_contract_rejected _)
  | Some (Keeper_turn_driver.Receipt_persistence_failed _) -> false
  | None -> false
