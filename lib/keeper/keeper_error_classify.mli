(** Keeper_error_classify — Error classification and side-effect safety for
    the unified keeper cycle.

    Extracted from keeper_unified_turn.ml.

    @since 0.122.0 *)

(** Typed provider availability diagnostic. This controls observation labels
    only and grants no candidate transition or replay authority. *)
val is_provider_availability_error : Agent_core.Error.t -> bool

(** [true] when a typed internal runner exception preserves a TLS failure
    raised inside {!Keeper_turn_driver.runtime_runner_execute_site}.
    Legacy internal exception envelopes without [transport_error_kind] are
    diagnostic-only and are not parsed heuristically. *)
val is_runner_tls_error : Agent_core.Error.t -> bool

(** Detect request body parse errors from either the provider or the API
    (e.g. Ollama yyjson rejecting a malformed request body or the API
    rejecting invalid JSON). The typed distinction is used for observability
    and runtime rotation; it never exempts a committed mutation from explicit
    partial-commit handling. *)
val is_server_rejected_parse_error : Agent_core.Error.t -> bool

(** [true] for provider-side request-body parse rejections. *)
val is_provider_rejected_parse_error : Agent_core.Error.t -> bool

(** [true] only for an accepted provider response whose wire contract failed:
    the [Provider_wire_error] kinds (malformed, unknown event, incomplete,
    oversized) across SSE and NDJSON. A [Provider_reported_error] — a
    structurally valid error envelope the provider put inside an accepted
    response — is deliberately NOT one of these, and returns [false].
    Used to select the diagnostic log suffix in the turn-failure path.
    Candidate rotation eligibility and consecutive-failure accounting are
    determined by {!Keeper_runtime_attempt}, not by this predicate. *)
val is_provider_wire_error : Agent_core.Error.t -> bool

(** [true] for model/API-side request-body parse rejections reported as
    [InvalidRequest]. *)
val is_model_rejected_parse_error : Agent_core.Error.t -> bool

(** [true] for API-side 400 rejections ([Api (InvalidRequest _)]): the
    provider refused the request body itself (malformed payload, orphan
    tool-call residues), so same-turn retry is futile. Rendered provider text
    carries no recovery authority. *)
val is_invalid_request_error : Agent_core.Error.t -> bool

(** [true] for a 0-byte empty completion: the provider ended the turn with a
    modeled, non-overflow stop_reason but returned no content.  Only the two
    typed AGENT_CORE shapes for this condition match (see the .ml); the unmodeled
    stop_reason shape that AGENT_CORE intentionally reports as non-retryable
    [InvalidRequest] does not. *)
val is_empty_completion_error : Agent_core.Error.t -> bool

(** [true] for accept-rejected responses tagged by the built-in keeper
    progress contract as no usable text/tool/non-terminal progress. *)
val is_accept_no_usable_progress_error : Agent_core.Error.t -> bool

(** [true] when the turn runner should record the immediate
    ["keeper cycle FAILED"] line as WARN instead of ERROR. This controls log
    severity only; it grants no retry, admission, pause, or blocker authority. *)
val should_warn_keeper_cycle_failed : Agent_core.Error.t -> bool

(** [true] for a typed API context overflow ([ContextOverflow]) only.  An
    [Error.Agent (UnrecognizedStopReason _)] is not classified here even when it
    carries an overflow token: see the note in the implementation. *)
val is_context_overflow : Agent_core.Error.t -> bool

(** [true] when the error is an AGENT_CORE [InputRequired] — the agent paused
    to request human input.  Not a failure; a special stop condition. *)
val is_input_required_error : Agent_core.Error.t -> bool

(** Extract the [InputRequired] payload from an [core_error], if any.
    Typed companion to {!is_input_required_error} — callers that need
    the [input_required] record (request_id, question, …) avoid a
    separate pattern match plus [assert false] when the predicate
    has already filtered for the constructor. *)
val extract_input_required
  :  Agent_core.Error.t
  -> Agent_core.Error.input_required option

(** [true] when an error represents terminal runtime exhaustion. *)
val is_runtime_exhausted_error : Agent_core.Error.t -> bool

val is_provider_timeout_error : Agent_core.Error.t -> bool
(** True when [err] is a typed provider-timeout class failure. Live caller:
    [keeper_unified_turn.ml] degraded-retry classification. *)

val is_receipt_lost_error : Agent_core.Error.t -> bool
(** True when [err] indicates a receipt-lost failure (the provider
    confirmed completion but the response payload was lost in transit).
    Live caller: [keeper_unified_turn.ml] failure-reason classification
    via the [EC] alias. *)
