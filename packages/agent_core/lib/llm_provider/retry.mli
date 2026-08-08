(** Structured provider/API error evidence and typed classification.

    @stability Internal
    @since 0.93.1 *)

(** {1 Error types} *)

type invalid_request_reason =
  | Json_parse_error
  | Request_body_too_large of
      { actual_bytes : int
      ; limit_bytes : int
      }
  (** Refused locally, before dispatch, against a declared byte limit. Both
          integers are measured: the serialized body and the limit it exceeded. *)
  | Request_body_refused_by_provider of { status : int }
  (** The provider refused the request for its size. Distinct from
          {!Request_body_too_large} because the limit is unknown here — the response
          carries a status, not a bound — and putting an estimate in those fields
          would make a measured pair mean something it does not.

          Separate from {!Unknown_invalid_request} because the cause is known: a
          smaller request may succeed, where a malformed one will not. A consumer
          that shrinks its input on the first and refuses to on the second needs the
          two apart. [status] rather than a bare marker so a provider that signals
          this with a status other than 413 leaves that fact in the type instead of
          in a comment. *)
  | Unknown_invalid_request

type input_capacity_reason =
  | Serving_constraint_rejected of Serving_constraint.admission_error
  | Token_measurement_unavailable of Input_token_count.protocol

type api_error =
  | RateLimited of
      { retry_after : float option
      ; message : string
      }
  | Overloaded of { message : string }
  | ServerError of
      { status : int
      ; message : string
      }
  | AuthError of { message : string } (** Authentication failed (HTTP 401). *)
  | AuthorizationError of { message : string }
  (** Authorization was refused (HTTP 403). *)
  | PaymentRequired of { message : string }
  | InvalidRequest of
      { message : string
      ; reason : invalid_request_reason
      }
  | NotFound of { message : string }
  | ContextOverflow of
      { message : string
      ; limit : int option
      }
  | InputCapacity of
      { message : string
      ; constraint_ : Serving_constraint.t
      ; reason : input_capacity_reason
      }
  | NetworkError of
      { message : string
      ; kind : Http_client.network_error_kind
      }
  | Timeout of
      { message : string
      ; phase : Http_client.timeout_phase option
      }

(** {1 Error classification} *)

val is_retryable : api_error -> bool
val error_message : api_error -> string

(** Verdict for a provider turn that produced no content blocks.

    [Empty_overflow] carries the typed [ContextOverflow]: only the consumer's
    context recovery (compaction) can make progress, because retrying or
    rotating replays the same oversized prompt. [Empty_attributed] means a
    recognized non-overflow stop_reason, for which the caller's existing
    provider-unavailability handling applies. [Empty_unattributed] carries the
    raw stop_reason token the SDK does not model: the caller must surface it
    instead of folding it into transient provider unavailability, which would
    retry the identical prompt forever and hide an overflow reported with an
    unmodeled token. Derived from the typed stop_reason alone — no provider
    identity is consulted. *)
type empty_completion_verdict =
  | Empty_overflow of api_error
  | Empty_attributed
  | Empty_unattributed of { token : string }

(** [verdict_of_empty_completion ~stop_reason ~message] is the single,
    compiler-checked classification of an empty provider completion. The match
    is exhaustive, so a new [Types.stop_reason] forces a decision here. *)
val verdict_of_empty_completion
  :  stop_reason:Types.stop_reason
  -> message:string
  -> empty_completion_verdict

(** [overflow_of_empty_completion ~stop_reason ~message] is the overflow-only
    projection of {!verdict_of_empty_completion}: [Some (ContextOverflow …)]
    when [stop_reason] is [ContextWindowExceeded], else [None]. Single
    compiler-checked source for the #2621 empty-completion overflow rule; the
    message prefix
    ["empty completion (stop_reason=model_context_window_exceeded): "] and
    [limit = None] live there so all call sites stay byte-identical. Callers
    that must distinguish an unmodeled stop_reason from a recognized
    non-overflow one use {!verdict_of_empty_completion} instead — this
    projection collapses both into [None]. *)
val overflow_of_empty_completion
  :  stop_reason:Types.stop_reason
  -> message:string
  -> api_error option

(** Merge a provider's structured [retry_after] evidence: the JSON body's
    [error.retry_after] field wins when present (provider-specific, more
    precise); the transport's parsed [Retry-After] response header
    ({!Http_client.parse_retry_after_seconds}) is the fallback. [None] when
    neither is present or parseable. *)
val resolve_retry_after : body:string -> header:float option -> float option

(** [retry_after_header] carries the transport's parsed [Retry-After]
    response header, if any ({!Http_client.HttpError.retry_after_header}).
    Required (not optional-with-default) so every call site states
    explicitly whether header evidence was available, rather than
    silently defaulting to [None]. On the 429 branch it is merged via
    {!resolve_retry_after}; on other branches it is unused (those statuses
    do not carry an HTTP-level retry hint in this classification). *)
val classify_error
  :  retry_after_header:float option
  -> status:int
  -> body:string
  -> api_error
