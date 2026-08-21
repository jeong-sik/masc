(** Keeper_error_classify — Error classification for the unified keeper cycle.

    Pure predicates and classification functions over [Agent_core.Error.t].
    No I/O, no state mutation.

    Extracted from keeper_unified_turn.ml.

    @since 0.122.0 *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

(** Exact typed runner TLS diagnostic. *)
let is_runner_tls_transport_error = function
  | Llm_provider.Http_client.Tls_error -> true
  | Llm_provider.Http_client.Connection_refused
  | Llm_provider.Http_client.Dns_failure
  | Llm_provider.Http_client.Timeout
  | Llm_provider.Http_client.Local_resource_exhaustion
  | Llm_provider.Http_client.End_of_file
  | Llm_provider.Http_client.Unknown ->
    false
;;

let is_runner_tls_error (err : Agent_core.Error.t) : bool =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some
      (Keeper_turn_driver.Internal_unhandled_exception
         { site; transport_error_kind = Some transport_error_kind; _ })
    when String.equal site Keeper_turn_driver.runtime_runner_execute_site ->
    is_runner_tls_transport_error transport_error_kind
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
      | Keeper_turn_driver.Receipt_persistence_failed _
      | Keeper_turn_driver.Gate_replay_repair_required _ )
  | None -> false

(** {1 Typed provider availability diagnostics} *)

let is_provider_availability_error (err : Agent_core.Error.t) : bool =
  if is_runner_tls_error err
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
  | Agent_core.Error.Provider (Llm_provider.Error.ServerError _) -> true
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
    (a broken backend model answering with an empty assistant turn).  AGENT_CORE
    surfaces exactly two shapes for this condition
    (agent_core [Api_error.verdict_of_empty_completion]):

    - [Provider (ProviderUnavailable {detail})] with [detail] starting
      ["empty completion (stop_reason="] — a recognized non-overflow
      stop_reason (e.g. [end_turn]) on an empty assistant turn, routed to
      provider-unavailability handling upstream.

    Deliberately excluded:

    - [Api (InvalidRequest _)] — AGENT_CORE flattens only the unmodeled-stop_reason
      and the context-overflow empty completions into [InvalidRequest].  The
      first is intentionally terminal (agent_core
      provider_failure_attribution.ml: retrying replays the identical prompt
      and never terminates); the second replays the same oversized prompt.
      Neither is recoverable by retry or failover, so no [InvalidRequest]
      message text is matched here — free-form provider bodies are not a
      classification source (see [is_provider_rejected_parse_error]).
    - ["Context overflow: empty completion"] — a context-overflow diagnostic,
      already classified by [is_context_overflow] on the typed path.

    Why a string prefix survives here (constitution exception, RFC-0371
    §3.7): the typed [stop_reason] is deliberately flattened into [detail]
    at the agent-core boundary (agent_core [Error.of_provider_failure],
    [Empty_attributed] arm), so by the time the error reaches MASC the
    prefix is the ONLY remaining discriminator between an empty-completion
    [ProviderUnavailable] and the other [ProviderUnavailable] producers
    (CLI startup failure, unknown provider failure). The marker is owned by
    a single renderer ([error.ml]: ["empty completion (stop_reason=%s): %s"]),
    not free-form provider prose. Re-typing requires a pinned Agent Core
    error-variant change; that pin update — not this classifier — is where
    the typed shape must be introduced. *)
let is_empty_completion_error (err : Agent_core.Error.t) : bool =
  match err with
  | Agent_core.Error.Provider
      (Llm_provider.Error.ProviderUnavailable { detail; _ }) ->
      String.starts_with ~prefix:"empty completion (stop_reason=" detail
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
      | Keeper_turn_driver.Receipt_persistence_failed _
      | Keeper_turn_driver.Gate_replay_repair_required _ )
  | None ->
    false

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
  | Some (Keeper_turn_driver.Receipt_persistence_failed _)
  | Some (Keeper_turn_driver.Gate_replay_repair_required _)
  | None ->
    false

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
  | Some (Keeper_turn_driver.Receipt_persistence_failed _)
  | Some (Keeper_turn_driver.Gate_replay_repair_required _) -> false
  | None -> false
