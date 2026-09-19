(** Keeper_error_classify — Error classification
    and retry constants for the unified keeper cycle.

    Pure predicates and classification functions over [Agent_core.Error.t].
    No I/O, no state mutation.

    Extracted from keeper_unified_turn.ml.

    @since 0.122.0 *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

(** Detect transient network errors that warrant retry with short backoff.
    Uses structured [Agent_core.Error.t] pattern matching instead of
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

let is_transient_internal_runner_error (err : Agent_core.Error.t) : bool =
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
      | Keeper_turn_driver.Incomplete_tool_transcript _
      | Keeper_turn_driver.Terminal_effect_failed _
      | Keeper_turn_driver.Provider_attempt_effect_fenced _
      | Keeper_turn_driver.Tool_correction_lost _
      | Keeper_turn_driver.Host_stopped_turn _
      | Keeper_turn_driver.Runtime_connection_closed _
      | Keeper_turn_driver.Receipt_persistence_failed _
      | Keeper_turn_driver.Gate_replay_repair_required _ )
  | None -> false

(** {1 Typed retry classification} *)

let is_transient_network_error (err : Agent_core.Error.t) : bool =
  if is_transient_internal_runner_error err
  then true
  else match err with
  | Agent_core.Error.Api (NetworkError _) -> true
  | Agent_core.Error.Api (Timeout _) -> true
  | Agent_core.Error.Provider (Llm_provider.Error.NetworkError
      { kind = Llm_provider.Http_client.Tls_error
             | Llm_provider.Http_client.Local_resource_exhaustion; _ }) ->
      false
  | Agent_core.Error.Provider (Llm_provider.Error.NetworkError _) -> true
  | Agent_core.Error.Provider (Llm_provider.Error.Timeout _) -> true
  | Agent_core.Error.Api (Overloaded _) -> true
  | Agent_core.Error.Provider (Llm_provider.Error.ServerError { transient; _ }) ->
      transient
  (* Non-transient API errors. *)
  | Agent_core.Error.Api (ServerError _)
  | Agent_core.Error.Api (RateLimited _)
  | Agent_core.Error.Api (AuthError _)
  | Agent_core.Error.Api (AuthorizationError _)
  | Agent_core.Error.Api (PaymentRequired _)
  | Agent_core.Error.Api (InvalidRequest _)
  | Agent_core.Error.Api (NotFound _)
  | Agent_core.Error.Api (ContextOverflow _)
  | Agent_core.Error.Api (InputCapacity _) -> false
  (* Non-API error families are by definition not transient network errors. *)
  | Agent_core.Error.Provider _
  | Agent_core.Error.Agent _
  | Agent_core.Error.Mcp _
  | Agent_core.Error.Config _
  | Agent_core.Error.Serialization _
  | Agent_core.Error.Io _
  | Agent_core.Error.Orchestration _
  | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried { message = _; _ } -> false

(** Detect typed server-side request body parse errors.  The LLM API never
    processed the request, so committed tool results are not at risk of
    duplication.

    These errors may recur with the same payload, so they are not eligible
    for same-turn retry. The keeper's next cycle remains available, but a
    committed mutation is never exempted from explicit partial-commit
    handling based on the tool's product identity.

    Deliberately do not infer this from [InvalidRequest] message text: provider
    bodies are free-form and have produced false positives for non-JSON parse
    errors.  If AGENT_CORE needs to recover these cases, it must expose a structured
    parse-error constructor before MASC classifies them here. *)

let is_provider_rejected_parse_error (err : Agent_core.Error.t) : bool =
  match err with
  | Agent_core.Error.Provider (Llm_provider.Error.ParseError _) -> true
  | Agent_core.Error.Provider
      ( Llm_provider.Error.InvalidRequest _
      | Llm_provider.Error.NetworkError _
      | Llm_provider.Error.Timeout _
      | Llm_provider.Error.ServerError _ | Llm_provider.Error.RateLimit _
      | Llm_provider.Error.AuthError _
      | Llm_provider.Error.AuthorizationError _
      | Llm_provider.Error.MissingApiKey _
      | Llm_provider.Error.NotFound _ | Llm_provider.Error.CapacityExhausted _
      | Llm_provider.Error.HardQuota _
      | Llm_provider.Error.ProviderUnavailable _
      | Llm_provider.Error.EmptyCompletion _
      | Llm_provider.Error.RepeatingGeneration _
      | Llm_provider.Error.ProviderTerminal _
      | Llm_provider.Error.ProviderWireError _
      | Llm_provider.Error.ProviderReportedError _
      | Llm_provider.Error.InvalidConfig _
      | Llm_provider.Error.UnknownVariant _) -> false
  | Agent_core.Error.Api _ -> false
  | Agent_core.Error.Agent _ -> false
  | Agent_core.Error.Mcp _ -> false
  | Agent_core.Error.Config _ -> false
  | Agent_core.Error.Serialization _ -> false
  | Agent_core.Error.Io _ -> false
  | Agent_core.Error.Orchestration _ -> false
  | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried { message = _; _ } -> false

let is_provider_wire_error (err : Agent_core.Error.t) : bool =
  match err with
  | Agent_core.Error.Provider (Llm_provider.Error.ProviderWireError _) -> true
  | Agent_core.Error.Provider _
  | Agent_core.Error.Api _
  | Agent_core.Error.Agent _
  | Agent_core.Error.Mcp _
  | Agent_core.Error.Config _
  | Agent_core.Error.Serialization _
  | Agent_core.Error.Io _
  | Agent_core.Error.Orchestration _
  | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried { message = _; _ } -> false

(** 0-byte empty completion: the provider ended the turn with a modeled,
    non-overflow stop_reason but returned no thinking, text, or tool calls
    (a broken backend model answering with an empty assistant turn).
    AGENT_CORE carries it as [Provider (EmptyCompletion {stop_reason; _})]
    (agent_core [Retry.verdict_of_empty_completion], [Empty_attributed]),
    with the typed stop_reason still on the value.

    Deliberately excluded:

    - [Api (InvalidRequest _)] — AGENT_CORE flattens only the unmodeled-stop_reason
      and the context-overflow empty completions into [InvalidRequest].  The
      first is intentionally non-retryable (agent_core
      provider_failure_attribution.ml: retrying replays the identical prompt
      and never terminates); the second replays the same oversized prompt.
      Neither is recoverable by retry or failover, so no [InvalidRequest]
      message text is matched here — free-form provider bodies are not a
      classification source (see [is_provider_rejected_parse_error]).
    - ["Context overflow: empty completion"] — a context-overflow diagnostic,
      already classified by [is_context_overflow] on the typed path. *)
let is_empty_completion_error (err : Agent_core.Error.t) : bool =
  match err with
  | Agent_core.Error.Provider (Llm_provider.Error.EmptyCompletion _) -> true
  (* [ParseError] is not an empty-completion shape: no producer renders the
     old "empty completion (no thinking" marker into a production
     [ParseError] at the pinned Agent Core (the renderer's callers are
     test-only), so the substring guard that used to sit here matched
     nothing. If a future Agent Core promotes empty completions to
     [ParseError], that pin update is the place to classify them — as a
     typed shape, not a message substring (RFC-0371 §3.7). *)
  | Agent_core.Error.Provider _ -> false
  | Agent_core.Error.Api _ -> false
  | Agent_core.Error.Agent _ -> false
  | Agent_core.Error.Mcp _ -> false
  | Agent_core.Error.Config _ -> false
  | Agent_core.Error.Serialization _ -> false
  | Agent_core.Error.Io _ -> false
  | Agent_core.Error.Orchestration _ -> false
  | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried { message = _; _ } -> false

let is_model_rejected_parse_error (err : Agent_core.Error.t) : bool =
  match err with
  | Agent_core.Error.Api (InvalidRequest _ | NetworkError _ | Timeout _
    | Overloaded _ | ServerError _ | RateLimited _ | AuthError _
    | AuthorizationError _ | NotFound _ | PaymentRequired _ | ContextOverflow _
    | InputCapacity _) ->
      false
  | Agent_core.Error.Provider _ -> false
  | Agent_core.Error.Agent _ -> false
  | Agent_core.Error.Mcp _ -> false
  | Agent_core.Error.Config _ -> false
  | Agent_core.Error.Serialization _ -> false
  | Agent_core.Error.Io _ -> false
  | Agent_core.Error.Orchestration _ -> false
  | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried { message = _; _ } -> false

let is_server_rejected_parse_error (err : Agent_core.Error.t) : bool =
  is_provider_rejected_parse_error err || is_model_rejected_parse_error err

(** Receipt I/O failure: the turn body succeeded but the authoritative
    receipt could not be persisted. The producer carries a typed MASC error;
    free-form error prose is never used as a behavioral discriminator. *)
let is_receipt_lost_error (err : Agent_core.Error.t) : bool =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Receipt_persistence_failed _) -> true
  | Some _ | None -> false

let is_provider_timeout_error (err : Agent_core.Error.t) : bool =
  Keeper_provider_runtime_boundary.is_provider_timeout_error err

let is_auto_recoverable_runtime_exhausted_error (err : Agent_core.Error.t) : bool =
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
      (* A decoded receipt from the retired pre-dispatch gate carries no
         lifecycle authority. *)
      true
  | Some (Keeper_turn_driver.Runtime_exhausted _) ->
      false
  | Some (Keeper_turn_driver.Accept_rejected _)
  | Some (Keeper_turn_driver.Resumable_cli_session _)
  (* RFC-0159 Phase A: opaque internal failures. *)
  | Some (Keeper_turn_driver.Internal_unhandled_exception _)
  | Some (Keeper_turn_driver.Internal_bridge_exception _)
  | Some (Keeper_turn_driver.Internal_contract_rejected _)
  | Some (Keeper_turn_driver.Incomplete_tool_transcript _)
  | Some (Keeper_turn_driver.Terminal_effect_failed _)
  | Some (Keeper_turn_driver.Provider_attempt_effect_fenced _)
  | Some (Keeper_turn_driver.Tool_correction_lost _)
  | Some (Keeper_turn_driver.Host_stopped_turn _)
  | Some (Keeper_turn_driver.Runtime_connection_closed _)
  | Some (Keeper_turn_driver.Receipt_persistence_failed _)
  | Some (Keeper_turn_driver.Gate_replay_repair_required _)
  | None ->
      false

let is_accept_no_usable_progress_error (err : Agent_core.Error.t) : bool =
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
      | Keeper_turn_driver.Incomplete_tool_transcript _
      | Keeper_turn_driver.Terminal_effect_failed _
      | Keeper_turn_driver.Provider_attempt_effect_fenced _
      | Keeper_turn_driver.Tool_correction_lost _
      | Keeper_turn_driver.Host_stopped_turn _
      | Keeper_turn_driver.Runtime_connection_closed _
      | Keeper_turn_driver.Receipt_persistence_failed _
      | Keeper_turn_driver.Gate_replay_repair_required _ )
  | None ->
    false

(* Why a turn continues on the next runtime of its lane. The producer is
   [recoverable_runtime_failure_reason]; the value labels the deferred lane
   suffix a failed turn leaves for the next one and the receipt that turn
   writes. Wire form is the lowercase string via
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
  | Deferred_runtime_lane
  | Empty_no_progress
  | Thinking_only_no_progress
  | Truncated_no_progress

let degraded_retry_reason_to_string = function
  | Hard_quota -> "hard_quota"
  | Resumable_cli_session -> "resumable_cli_session"
  | Runtime_candidates_filtered -> "runtime_candidates_filtered"
  | Runtime_exhausted -> "runtime_exhausted"
  | Capacity_backpressure -> "capacity_backpressure"
  | Rate_limit -> "rate_limit"
  | Server_error -> "server_error"
  | Auth_error -> "auth_error"
  | Deferred_runtime_lane -> "deferred_runtime_lane"
  | Empty_no_progress -> "empty_no_progress"
  | Thinking_only_no_progress -> "thinking_only_no_progress"
  | Truncated_no_progress -> "truncated_no_progress"

let accept_rejection_degraded_retry_reason err =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some internal_error ->
    (match Keeper_turn_driver.accept_no_progress_retry_kind internal_error with
     | Some `Empty_no_progress -> Some Empty_no_progress
     | Some `Thinking_only_no_progress -> Some Thinking_only_no_progress
     | Some `Truncated_no_progress -> Some Truncated_no_progress
     | None -> None)
  | None -> None

type degraded_retry =
  { next_runtime : string
  ; fallback_reason : degraded_retry_reason
  }

let recoverable_runtime_failure_reason (err : Agent_core.Error.t) =
  if Keeper_runtime_failure_route.core_error_is_hard_quota err then
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
           specific reason. It still names a reason, so a receipt does not
           end with a [(null)] fallback_reason: receipt-derived data on
           2026-04-25 showed 31/39 silent turns did while this arm returned
           [None]. *)
        Some Runtime_exhausted
    | Some (Keeper_turn_driver.Accept_rejected _) ->
        accept_rejection_degraded_retry_reason err
    (* A closed runtime connection reached this function as agent-core's
       [ProviderUnavailable] before RFC-0454 P2 typed it, and the arm below
       for that constructor answers [Server_error]. The typed value does not
       move the deferred whole-runtime lane, so it answers the same. *)
    | Some (Keeper_turn_driver.Runtime_connection_closed _) -> Some Server_error
    (* RFC-0159 Phase A: typed [Internal_*] variants are not runtime-rotation
       reasons; they expose previously-opaque raw exception payloads.  *)
    | Some (Keeper_turn_driver.Internal_unhandled_exception _)
    | Some (Keeper_turn_driver.Internal_bridge_exception _)
    | Some (Keeper_turn_driver.Internal_contract_rejected _)
    | Some (Keeper_turn_driver.Incomplete_tool_transcript _)
    | Some (Keeper_turn_driver.Terminal_effect_failed _)
    | Some (Keeper_turn_driver.Provider_attempt_effect_fenced _)
    | Some (Keeper_turn_driver.Tool_correction_lost _)
    (* The host stopped the turn; a second runtime would re-run what was
       stopped on purpose. Untyped, this was an [Internal] string and reached
       the same answer. *)
    | Some (Keeper_turn_driver.Host_stopped_turn _)
    | Some (Keeper_turn_driver.Receipt_persistence_failed _)
    | Some (Keeper_turn_driver.Gate_replay_repair_required _) ->
        None
    | None ->
        (* Raw provider API errors that are not wrapped in a MASC internal
           error (e.g. single-provider runtimes where AGENT_CORE surfaces the
           error directly) get a label too, so the deferred lane suffix records
           why the turn continued on its next lane candidate.

           429 rate-limit (non-hard-quota): [Rate_limit]. The error type does
           not carry model/account/provider scope, so this boundary does not
           infer a broader blocked set.

           [ServerError]: [Server_error]; the provider is unhealthy or
           overloaded.

           401/403: [Auth_error]; the credential for this runtime is invalid.

           [PaymentRequired] and provider [HardQuota] are handled above by
           [core_error_is_hard_quota]. *)
        (match err with
         | Agent_core.Error.Api (Llm_provider.Retry.RateLimited _) ->
             Some Rate_limit
         | Agent_core.Error.Api (Llm_provider.Retry.Overloaded _) ->
             Some Capacity_backpressure
         | Agent_core.Error.Api (Llm_provider.Retry.ServerError _) ->
             Some Server_error
         | Agent_core.Error.Api
             ( Llm_provider.Retry.AuthError _
             | Llm_provider.Retry.AuthorizationError _ ) ->
             Some Auth_error
         | Agent_core.Error.Provider
             (Llm_provider.Error.RateLimit _) ->
             Some Rate_limit
         | Agent_core.Error.Provider (Llm_provider.Error.CapacityExhausted _) ->
             Some Capacity_backpressure
         | Agent_core.Error.Provider (Llm_provider.Error.HardQuota _) ->
             Some Hard_quota
         | Agent_core.Error.Provider
             (Llm_provider.Error.ServerError { transient = true; _ }) ->
             Some Server_error
         | Agent_core.Error.Provider
             ( Llm_provider.Error.ProviderUnavailable _
             | Llm_provider.Error.EmptyCompletion _ ) ->
             Some Server_error
         | Agent_core.Error.Provider
             ( Llm_provider.Error.AuthError _
             | Llm_provider.Error.AuthorizationError _
             | Llm_provider.Error.MissingApiKey _ ) ->
             Some Auth_error
         (* Wire/provided-response failures are intentionally excluded here.
            This function selects a deferred whole-runtime lane after the
            current candidate walk; same-turn candidate rotation is already
            decided by [Keeper_runtime_attempt] mapping these typed facts to
            [ProviderFailure]. Reclassifying them here would conflate the two
            boundaries and schedule a second whole-runtime wake for the same
            malformed provider response. *)
         | Agent_core.Error.Provider
             (Llm_provider.Error.ServerError _
             | Llm_provider.Error.InvalidConfig _
             | Llm_provider.Error.InvalidRequest _
             | Llm_provider.Error.NotFound _
             | Llm_provider.Error.NetworkError _
             | Llm_provider.Error.Timeout _
             | Llm_provider.Error.ParseError _
             | Llm_provider.Error.ProviderWireError _
             (* A repeating generation rotates within the turn: the driver
                maps it to [ProviderFailure] and leaves the model behind. *)
             | Llm_provider.Error.RepeatingGeneration _
             | Llm_provider.Error.ProviderReportedError _
             | Llm_provider.Error.UnknownVariant _
             | Llm_provider.Error.ProviderTerminal _) ->
             None
         | Agent_core.Error.Api (Llm_provider.Retry.PaymentRequired _)
         | Agent_core.Error.Api (Llm_provider.Retry.InvalidRequest _)
         | Agent_core.Error.Api (Llm_provider.Retry.NotFound _)
         | Agent_core.Error.Api (Llm_provider.Retry.ContextOverflow _)
         | Agent_core.Error.Api (Llm_provider.Retry.InputCapacity _)
         | Agent_core.Error.Api (Llm_provider.Retry.NetworkError _)
         | Agent_core.Error.Api (Llm_provider.Retry.Timeout _) -> None
         (* Non-API error families have no rotation reason here: structured
            MASC internal errors are handled by [classify_masc_internal_error]
            above; agent / mcp / config / etc. are not provider-level rotations. *)
         | Agent_core.Error.Agent _
         | Agent_core.Error.Mcp _
         | Agent_core.Error.Config _
         | Agent_core.Error.Serialization _
         | Agent_core.Error.Io _
         | Agent_core.Error.Orchestration _
         | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried { message = _; _ } -> None)

(** [true] only for the typed API-side 400 rejection. Rendered provider text
    carries no recovery authority. *)
let is_invalid_request_error : Agent_core.Error.t -> bool = function
  | Agent_core.Error.Api (InvalidRequest _) -> true
  | _ -> false

(** [true] when a structured error indicates context overflow.

    The [UnrecognizedStopReason { reason = "model_context_window_exceeded" }] arm
    was removed. Not because agent core cannot construct that value — it can: only
    [Types.stop_reason_of_string] maps the overflow tokens to the typed
    [ContextWindowExceeded]; the Ollama backend, the Ollama NDJSON terminal
    chunk, and the OpenAI Responses decoder each build [Types.Unknown <raw>]
    without consulting it, and [pipeline.ml] turns [Unknown] into
    [UnrecognizedStopReason]. It was removed because classifying an
    [Error.Agent _] as a context overflow here is a string classifier standing in
    for a typed provider signal, and no production caller consumed the result:
    the live classifiers ([Keeper_turn_runtime_budget.capacity_transition_of_error],
    [Keeper_turn_driver_try_runtime]) already treat every [Error.Agent _] as
    not-overflow. Routing an Ollama-dialect overflow belongs in AGENT_CORE, at the
    decoders that bypass [stop_reason_of_string]. *)
let is_context_overflow (err : Agent_core.Error.t) : bool =
  match err with
  | Agent_core.Error.Api (ContextOverflow _) -> true
  | Agent_core.Error.Api (InputCapacity _) -> false
  | _ -> false

(* Classification-only predicate: does this failure class describe a
   condition a later turn could clear without operator action?

   RFC turn-failure-visible-stop (#32105): this predicate has NO crash
   accounting authority. Every turn failure advances the durable
   crash-accounting streak in [Keeper_unified_turn_failure] regardless of
   class; the next successful turn (or an operator clear) resets it. The
   historical design exempted "auto-recoverable" classes from crash
   accounting and required each exemption to carry its own compensating
   budget. That invariant lived only in this comment and drifted from the
   code twice: a provider emitting a malformed stream looped 923 rejections
   across five keepers in 1h41m on 2026-07-21, and a fleet-wide transport
   outage retried forever with [consecutive] pinned at 0 and fleet health
   [ok] (#31958, 44 failures in 59s). No classification decides whether a
   failure is visible.

   What this predicate still feeds: telemetry labels and downstream failure
   routing (see [Keeper_runtime_failure_route]). A failed turn never leaves
   its lane: the lane walk tries the declared candidates and stops. The heartbeat durably
   moves a failed source to its urgency-lane tail, so a persistently failing
   transport cannot monopolize other independent queued sources; the source
   is retained with a new incarnation and may be retried after independent
   work. Those are handling choices for the next attempt, not visibility
   decisions. *)
let is_auto_recoverable_turn_error (err : Agent_core.Error.t) : bool =
  is_transient_network_error err
  || is_auto_recoverable_runtime_exhausted_error err
  || is_empty_completion_error err
  || is_invalid_request_error err

let should_warn_keeper_cycle_failed (err : Agent_core.Error.t) : bool =
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
  | Some (Keeper_turn_driver.Incomplete_tool_transcript _)
  | Some (Keeper_turn_driver.Terminal_effect_failed _)
  | Some (Keeper_turn_driver.Provider_attempt_effect_fenced _)
  | Some (Keeper_turn_driver.Tool_correction_lost _)
  | Some (Keeper_turn_driver.Host_stopped_turn _)
  | Some (Keeper_turn_driver.Runtime_connection_closed _)
  | Some (Keeper_turn_driver.Receipt_persistence_failed _)
  | Some (Keeper_turn_driver.Gate_replay_repair_required _)
  | None ->
    false

(* [is_context_overflow] now lives earlier in this file, above
   [is_auto_recoverable_turn_error], since that predicate depends on it. *)

(** Extract the [InputRequired] payload from an [core_error], if any.
    Typed companion to {!is_input_required_error}; callers that need
    the [input_required] record use this option-returning function so
    a [match ... | _ -> assert false] tail is no longer required. *)
let extract_input_required (err : Agent_core.Error.t)
  : Agent_core.Error.input_required option
  =
  match err with
  | Agent_core.Error.Agent (Agent_core.Error.InputRequired ir) -> Some ir
  | _ -> None
;;

(** [true] when the error is an AGENT_CORE [InputRequired] — the agent paused
    to request human input.  Not a failure; a special stop condition. *)
let is_input_required_error (err : Agent_core.Error.t) : bool =
  match err with
  | Agent_core.Error.Agent (Agent_core.Error.InputRequired _) -> true
  | Agent_core.Error.Agent (UnrecognizedStopReason _)
  | Agent_core.Error.Agent (ToolRoundLimitExceeded _)
  | Agent_core.Error.Agent (HookExecutionFailed _)
  | Agent_core.Error.Agent (TerminalToolEffectFailed _)
  | Agent_core.Error.Agent (TerminalToolDurabilityFailed _)
  | Agent_core.Error.Agent (GuardrailViolation _)
  | Agent_core.Error.Agent (TripwireViolation _) -> false
  | Agent_core.Error.Api _
  | Agent_core.Error.Provider _
  | Agent_core.Error.Mcp _
  | Agent_core.Error.Config _
  | Agent_core.Error.Serialization _
  | Agent_core.Error.Io _
  | Agent_core.Error.Orchestration _
  | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried { message = _; _ } -> false

(** [true] when an error represents terminal runtime exhaustion. Accept
    rejection is an accept-contract result; no-progress accept rejection is
    classified separately so it does not masquerade as all-runtimes-exhausted. *)
let is_runtime_exhausted_error (err : Agent_core.Error.t) : bool =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Runtime_exhausted _)
  | Some (Keeper_turn_driver.Resumable_cli_session _) -> true
  | Some (Keeper_turn_driver.Capacity_backpressure _)
  | Some (Keeper_turn_driver.Accept_rejected _)
  (* RFC-0159 Phase A: opaque internal failures are not runtime exhaustion. *)
  | Some (Keeper_turn_driver.Internal_unhandled_exception _)
  | Some (Keeper_turn_driver.Internal_bridge_exception _)
  | Some (Keeper_turn_driver.Internal_contract_rejected _)
  | Some (Keeper_turn_driver.Incomplete_tool_transcript _)
  | Some (Keeper_turn_driver.Terminal_effect_failed _)
  | Some (Keeper_turn_driver.Provider_attempt_effect_fenced _)
  | Some (Keeper_turn_driver.Tool_correction_lost _)
  | Some (Keeper_turn_driver.Host_stopped_turn _)
  | Some (Keeper_turn_driver.Runtime_connection_closed _)
  | Some (Keeper_turn_driver.Receipt_persistence_failed _)
  | Some (Keeper_turn_driver.Gate_replay_repair_required _) -> false
  | None -> false
