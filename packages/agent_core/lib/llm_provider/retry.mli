(** Structured provider/API error evidence and typed classification.

    @stability Internal
    @since 0.93.1 *)

(** {1 Error types} *)

type invalid_request_reason =
  | Json_parse_error
  | Attempt_rejected
      (** The selected provider binding rejected the prepared request before
          dispatch. A caller with an ordered runtime lane may try a different
          binding, while retrying the same binding cannot change the result. *)
  | Request_body_refused_by_provider of { status : int }
  (** The provider refused the request for its size. The response carries a
          status, not a bound, and no bound is estimated here.

          Separate from {!Unknown_invalid_request} because the cause is known: a
          smaller request may succeed, where a malformed one will not. A consumer
          that shrinks its input on the first and refuses to on the second needs the
          two apart. [status] rather than a bare marker so a provider that signals
          this with a status other than 413 leaves that fact in the type instead of
          in a comment. *)
  | Refusal_body_not_received
      (** The provider refused and the body that would have named the cause
          did not arrive before the caller's own window closed
          ({!Http_client.Not_received_in_window}). Distinct from
          {!Unknown_invalid_request}, where the body arrived and named
          nothing this classifier knows: there the provider has spoken, here
          it has not been heard. Retryable for that reason -- the next
          attempt opens a fresh window -- while a refusal whose body arrived
          ends the attempt. *)
  | Unknown_invalid_request
      (** From {!classify_error}: an HTTP 400 or 422 whose body named nothing
          this classifier knows. Other producers fold their own untyped
          failures here. *)
  | Unclassified_status of { status : int }
      (** From {!classify_error}: a status that no other arm names (3xx, 405,
          408, 409, ...). Kept apart from {!Unknown_invalid_request} because
          it is not a 400 or 422 refusal of the request. The consumers that
          existed before it read it exactly as {!Unknown_invalid_request};
          only the Librarian slot outcome (RFC librarian §7.2) reads it
          differently, as a slot that did not answer. *)

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
  | Connect_failed of
      { message : string
      ; kind : Http_client.network_error_kind
      }
  (** {!Http_client.Connect_failed} carried across: the connection to the
      origin did not open, so the request was not sent (RFC #52028 §2.3). *)
  | Timeout of
      { message : string
      ; phase : Http_client.timeout_phase option
      }

type server_status_class =
  | Overloaded_status
  | Server_error_status
(** Typed classification of the complete HTTP server-error status class.
    HTTP 529 follows Anthropic's overload convention; every other code in
    500..599 is a server error. Codes outside that closed interval are not server status
    refusals, even when a transport accepts an unregistered integer code.
    See {{:https://platform.claude.com/docs/en/api/errors}Anthropic's error reference}. *)

(** {1 Error classification} *)

val is_retryable : api_error -> bool
val error_message : api_error -> string

val server_status_class_of_code : int -> server_status_class option
(** Single status-only source used by refusal classification and durable-evidence
    validation. Exact flow consumes the classified refusal. *)

(** Verdict for a provider turn that produced no content blocks.

    [Empty_overflow] carries the typed [ContextOverflow]: only the consumer's
    context recovery (compaction) can make progress, because retrying or
    rotating replays the same oversized prompt. [Empty_attributed] means a
    recognized non-overflow stop_reason, for which the caller's existing
    provider-unavailability handling applies. [Empty_unattributed] carries the
    raw stop_reason token agent core does not model: the caller must surface it
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

(** Merge a provider's structured [retry_after] evidence: the JSON body's
    [error.retry_after] field wins when present (provider-specific, more
    precise); the transport's parsed [Retry-After] response header
    ([Http_retry_after.parse_seconds]) is the fallback. [None] when
    neither is present or parseable. *)
val resolve_retry_after : body:string -> header:float option -> float option

(** Structured machine-readable classification extracted strictly from provider
    JSON error fields ([error.code], [error.error_code], [error.type],
    [error.error_type], [error.status], [error.metadata.error_type],
    [error.details[].reason], and nested JSON [error.metadata.raw]), never from
    free-form prose messages. *)
type error_signals =
  { codes : string list
  ; types : string list
  ; statuses : string list
  ; detail_reasons : string list
  ; messages : string list
  ; n_ctx : int option
  }

(** Extract machine-readable {!error_signals} directly from an already-parsed
    JSON provider error object (supporting nested [error.metadata.raw] JSON up
    to depth 2). *)
val signals_of_json : Yojson.Safe.t -> error_signals

(** Parse a JSON response body and extract {!error_signals}. Returns empty
    signals for non-JSON payloads. *)
val signals_of_body : string -> error_signals

(** Extract an explicit HTTP refusal status code ([400..599]) from structured
    JSON fields ([http_status], [httpStatus], [status_code], [statusCode],
    integer [status], or integer [code] inside [400..599], recursing into
    [error] and [metadata.raw]). Negative JSON-RPC codes (such as [-32000])
    and non-HTTP vendor codes (such as [1113] or [2303]) return [None]. *)
val http_status_of_json : Yojson.Safe.t -> int option

(** Extract a validated, finite, non-negative retry delay in seconds from a
    JSON provider error payload. Precedence within each object (nested [error],
    outer object, then [metadata.raw] up to depth 2):
    1. numeric [retry_after],
    2. numeric [retryAfter],
    3. Google [details[]] entry with [@type] equal to
       ["type.googleapis.com/google.rpc.RetryInfo"] or ["google.rpc.RetryInfo"]
       and strict protobuf duration [retryDelay] (["<digits>[.<digits>]s"]). *)
val retry_after_of_json : Yojson.Safe.t -> float option

(** True when structured {!error_signals} carry a recognized machine-readable
    context-window overflow code, type, status, or detail reason. *)
val signals_indicate_context_overflow : error_signals -> bool

(** True when structured {!error_signals} carry a recognized machine-readable
    account quota or billing exhaustion code, type, status, or detail reason. *)
val signals_indicate_account_quota : error_signals -> bool

type structured_refusal =
  | Structured_context_overflow of
      { message : string
      ; limit : int option
      }
  | Structured_account_quota of
      { message : string
      ; retry_after : float option
      }

(** Extract a typed {!structured_refusal} directly from an HTTP status and an
    already-parsed JSON error object without re-serializing JSON to string.
    Non-finite or negative [?retry_after] hints are rejected to [None]. *)
val structured_refusal_of_json
  :  ?retry_after:float
  -> status:int
  -> Yojson.Safe.t
  -> structured_refusal option

(** Extract a typed {!structured_refusal} from an HTTP refusal status and JSON
    body when the provider emitted a recognized machine-readable error code or
    type (or a retry hint on HTTP 403). Returns [None] for unstructured prose or
    ordinary request/permission errors. *)
val classify_structured_refusal
  :  retry_after_header:float option
  -> status:int
  -> body:string
  -> structured_refusal option

(** Status-optional structured refusal classification shared across HTTP
    backends and non-HTTP official clients (ACP JSON-RPC, CLI JSON envelopes).
    Derived strictly from optional HTTP status evidence and machine-readable
    JSON error fields or exact wire tokens; free-form prose never triggers
    classification. *)
type signal_refusal =
  | Signal_context_overflow of
      { message : string
      ; limit : int option
      }
  | Signal_request_body_too_large of { message : string }
  | Signal_hard_quota of
      { message : string
      ; retry_after : float option
      }
  | Signal_rate_limited of
      { message : string
      ; retry_after : float option
      }
  | Signal_auth_error of { message : string }
  | Signal_authorization_error of { message : string }
  | Signal_provider_unavailable of { message : string }

(** Classify structured {!error_signals} (with optional HTTP status and
    [retry_after] evidence) into a closed {!signal_refusal}. Non-finite or
    negative [?retry_after] delays are rejected to [None].
    - On HTTP [400] / [422], delegates directly to {!structured_refusal_of_signals}
      so HTTP {!classify_error} and status-qualified signal classification share
      one precedence table ([overflow > quota], plus Anthropic 400 billing parity).
    - On HTTP [413], returns {!Signal_request_body_too_large} (preserving parity
      with {!classify_error}'s [Request_body_refused_by_provider] instead of
      fabricating a context-window overflow).
    - When a status-less payload carries both quota and overflow signals, quota
      takes precedence so spent accounts rest instead of shrinking context.
    Returns [None] when no recognized HTTP refusal status ([400..599]) or
    structured machine signal is present. *)
val classify_structured_signals
  :  ?http_status:int
  -> ?retry_after:float
  -> ?fallback_message:string
  -> error_signals
  -> signal_refusal option

(** Classify an already-parsed JSON error payload (such as ACP JSON-RPC
    [error.data] or a CLI JSON error envelope) via {!signals_of_json},
    {!http_status_of_json}, {!retry_after_of_json}, and
    {!classify_structured_signals}. A caller-supplied [?http_status] in
    [400..599] takes precedence over JSON status fields (non-refusal values
    such as [200] or negative JSON-RPC codes fall back to
    {!http_status_of_json}); JSON [retry_after] takes precedence over
    caller-supplied [?retry_after]. *)
val classify_structured_json
  :  ?http_status:int
  -> ?retry_after:float
  -> ?fallback_message:string
  -> Yojson.Safe.t
  -> signal_refusal option

(** Extract balanced JSON object envelope(s) embedded inside a CLI or RPC error
    string and classify the first structured match via
    {!classify_structured_json}. Returns [None] when no valid structured JSON
    refusal envelope is present. *)
val classify_embedded_json
  :  ?http_status:int
  -> ?retry_after:float
  -> string
  -> signal_refusal option

(** Extract an explicit ASCII-boundary [HTTP[/ver] <status>] refusal status
    code ([401], [402], [403], [413], [429], or recognized [5xx] server/overload
    codes) from a plain text error message. Rejects malformed status tokens
    such as ["HTTP 4290"], ["HTTP 500-byte"], or ["HTTP 403/404"]. *)
val http_status_of_machine_tokens : string -> int option

(** Classify an error string strictly by exact ASCII-boundary machine wire
    codes (such as [RESOURCE_EXHAUSTED], [UNAUTHENTICATED],
    [PERMISSION_DENIED], [exceeded_current_quota_error],
    [context_length_exceeded], [GoUsageLimitError], or exact
    [reason=QUOTA_EXHAUSTED]) and explicit [HTTP <4xx|5xx>]
    status tokens, delegating to {!classify_structured_signals}. Free-form
    English prose (such as ["permission denied"], ["forbidden"], ["throttled"],
    ["token limit"], or ["prompt exceeds maximum context length"]) is never
    matched and returns [None]. *)
val classify_machine_tokens
  :  ?http_status:int
  -> ?retry_after:float
  -> string
  -> signal_refusal option

(** Unified text-surface refusal classifier shared across non-HTTP clients
    (ACP JSON-RPC [message], Antigravity CLI [Turn_failed] detail, and
    stringified [error.data]). Combines caller [?http_status],
    {!http_status_of_machine_tokens}, {!classify_embedded_json}, and exact
    machine tokens under one authoritative HTTP status precedence gate so an
    explicit HTTP [401]/[402]/[403]/[413]/[429]/[5xx] status in either caller
    metadata or text can never be downgraded into {!Signal_context_overflow}. *)
val classify_text
  :  ?http_status:int
  -> ?retry_after:float
  -> string
  -> signal_refusal option

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

(** {!classify_error} over a transport's refusal. A [Received] body is
    classified from what it says; [Not_received_in_window] is classified
    from the status alone, as {!Refusal_body_not_received}. *)
val classify_refusal
  :  retry_after_header:float option
  -> status:int
  -> body:Http_client.refusal_body
  -> api_error
