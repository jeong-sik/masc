(** HTTP client for LLM provider endpoints.

    Eio + cohttp-eio with TLS via {!Api_common.make_https}.
    Network and HTTP errors are captured as {!http_error},
    so callers do not need [try/with] around HTTP operations.

    @stability Internal
    @since 0.93.1 *)

(** Structured classification of network errors.
    Enables consumers to pattern-match on error kind instead of
    parsing message strings.

    @since 0.171.0 *)
type network_error_kind =
  | Connection_refused
  (** Remote endpoint actively refused the connection (ECONNREFUSED). *)
  | Dns_failure (** Hostname resolution failed or returned no results. *)
  | Tls_error
  (** TLS handshake, certificate validation, trust-store discovery, or TLS
      protocol processing failed. *)
  | Timeout (** Connection or read timed out (ETIMEDOUT). *)
  | Local_resource_exhaustion
  (** Local OS resource limits reached (EMFILE, ENFILE, ENOBUFS, EADDRNOTAVAIL). *)
  | End_of_file (** Peer closed the connection unexpectedly. *)
  | Unknown (** Unclassified network error. *)

(** Last observed streaming state when an inter-line idle deadline fired.

    This is deliberately transport-generic.  Provider-specific parsers
    translate chunks into OAS SSE events first; the timeout evidence only
    records the broad activity the stream was in when progress stopped. *)
type stream_idle_state =
  | Awaiting_first_event
  | Awaiting_first_delta
  | Streaming_answer
  | Streaming_thinking
  | Streaming_tool_call
  | Streaming_heartbeat
  | Streaming_substrate
  | Streaming_done
  | Streaming_unknown
[@@deriving yojson, show]

(** Typed timeout source.

    [NetworkError { kind = Timeout; _ }] still exists for low-level OS or
    legacy timeouts.  New call-site-owned deadlines should surface as
    {!TimeoutError} with one of these phases so downstream policy can
    distinguish admission checks, scheduler queueing, first-token wait,
    streaming idleness, whole-call wall clocks, capacity backpressure,
    transport/body deadlines, CLI stdout idleness,
    and generic caller budgets. *)
type timeout_phase =
  | Admission
  (** Pre-flight provider/capability/admission checks before a request is
      allowed to spend body budget. *)
  | Queue
  (** Waiting for an internal scheduler, slot, or provider queue before the
      request starts producing provider output. *)
  | First_token
  (** Request was accepted and submitted, but no first user-visible token or
      delta arrived before the deadline. *)
  | Wall_clock
  (** Whole operation wall-clock deadline, independent of streaming progress. *)
  | Capacity_backpressure
  (** Provider or local capacity pressure rejected or delayed the request
      before normal request execution. *)
  | Http_operation
  | Non_streaming_body
  | Stream_body
  | Stream_idle of stream_idle_state
  | Provider_step
  | Cli_stdout_idle
  | Unknown_timeout
[@@deriving yojson, show]

(** Provider-internal terminal condition reported via structured exit.

    Distinct from {!network_error_kind}: the subprocess/API ran to
    completion and emitted a structured stop reason on stdout.  Burying
    these as [NetworkError] loses the information that downstream
    callers need to handle the condition without treating it as a flaky
    network failure.

    @since 0.178.0 *)
type provider_terminal_kind =
  | Session_conflict
  (** The managed provider reported that this session cannot continue because
      another owner/process has the same session lease.  This is deliberately
      typed so downstream policy never parses CLI prose. *)
  | Other of string
  (** Forward-compatible bucket for unrecognized subtypes
          (e.g. [error_during_execution], [error_max_thinking_tokens]).
          Carries the raw subtype string so consumers can log it
          without flag day for new variants. *)

(** Scope attached to provider failure classifications.

    This is deliberately about the failed lane, not about retry policy.
    Retry policy lives above this transport layer. *)
type provider_failure_scope =
  | Failure_scope_model
  | Failure_scope_account
  | Failure_scope_region
  | Failure_scope_provider
  | Failure_scope_unknown

(** Typed managed-CLI startup failure.  Human diagnostics stay in the enclosing
    [ProviderFailure.message]; control flow branches only on this closed type. *)
type cli_startup_failure_reason =
  | Executable_unavailable
  | Authentication_unavailable
  | Session_conflict_at_startup
  | Configuration_invalid
  | Unknown_cli_startup_failure
[@@deriving yojson, show]

val cli_startup_failure_reason_to_string : cli_startup_failure_reason -> string

(** Transport-independent wire format observed after the HTTP response was
    accepted.  The format is evidence about the provider response, not a
    retry decision. *)
type provider_wire_format =
  | Sse
  | Ndjson

(** Closed classification of a provider wire failure.  The diagnostic
    message retains the parser's detail; control flow branches on this type,
    never on that message. *)
type provider_wire_error_kind =
  | Malformed_payload
  | Unknown_event
  | Incomplete_stream
  | Oversized_payload
  (** One payload unit — a joined SSE event, or a single line — exceeded the
        byte limit this client reads under. Distinct from
        [Malformed_payload]: the bytes are well-formed, there are too many. *)

val provider_wire_format_to_string : provider_wire_format -> string
val provider_wire_error_kind_to_string : provider_wire_error_kind -> string

(** Provider/runtime failure surfaced by a transport after it has parsed
    provider-specific HTTP/CLI details at the edge.

    Downstream code should pattern-match on this type instead of parsing
    stderr, HTTP bodies, or vendor-specific status strings. *)
type provider_failure_kind =
  | Capacity_exhausted of
      { scope : provider_failure_scope
      ; retry_after : float option
      ; model : string option
      }
  | Hard_quota of { retry_after : float option }
  | Capability_mismatch of { capability : string option }
  | Cli_policy_invalid of
      { tool_name : string option
      ; rule : int option
      }
  | Cli_startup_failed of { reason : cli_startup_failure_reason }
  | Provider_parse_error of { parser : string option }
  | Provider_wire_error of
      { format : provider_wire_format
      ; kind : provider_wire_error_kind
      }
  (** The HTTP response was accepted, but its provider-owned stream did not
      satisfy the declared wire contract.  This is distinct from an HTTP
      status such as 429 and from a provider-reported error envelope. *)
  | Provider_reported_error of { error_type : string option }
  (** The provider sent a structurally valid error envelope inside an
      otherwise accepted response.  [error_type] is provider-owned diagnostic
      data; OAS does not infer rate-limit or retry semantics from it. *)
  | Request_body_too_large of
      { actual_bytes : int
      ; limit_bytes : int
      }
  (** The exact serialized provider request exceeded the resolved target's
      declared transport boundary.  This is produced before dispatch and is
      independent from the model context-token window. *)
  | Response_body_too_large of { limit_bytes : int }
  (** The provider response exceeded the explicit in-memory parser boundary.
      The connection is closed immediately; OAS never drains an unbounded
      remainder merely to preserve connection reuse. *)
  | Empty_completion of { stop_reason : Types.stop_reason }
  (** oas#2483: a 200 with no deliverable content (no thinking/text/tool_calls).
      The typed stop reason is preserved so downstream policy can distinguish,
      for example, [MaxTokens] from [EndTurn] without parsing diagnostics. *)
  | Context_overflow of { limit : int option }
  (** oas#2947: the provider reported in its error envelope that the request
      exceeded the model context window (e.g. glm code 1261 "Prompt exceeds
      max length"). Distinct from [Request_body_too_large] (a pre-dispatch
      transport byte boundary) and from an empty completion whose
      [stop_reason] is [ContextWindowExceeded] (the same condition reported
      through a 200). Retrying or rotating replays the same oversized prompt;
      only the consumer's context recovery (compaction/shrink) can make
      progress. [limit] is the provider-reported token limit when the
      envelope carries one. *)
  | Unknown_provider_failure of { reason : string option }

(** Transport-level error. *)
type http_error =
  | HttpError of
      { code : int
      ; body : string
      ; retry_after_header : float option
        (** Parsed [Retry-After] response header (RFC 9110 S10.2.3), resolved
          to a delay in seconds relative to when the response was observed.
          [None] when the header was absent, malformed, or when the call
          site producing this error only has [(code, body)] available and
          never saw response headers (see {!get_sync}/{!post_sync}, whose
          callers construct [HttpError] themselves without header access).
          This is diagnostic transport evidence only; provider-specific
          JSON body fields (e.g. an [error.retry_after] number) remain the
          more precise signal and take priority over this field wherever
          both are consulted. *)
      }
  | NetworkError of
      { message : string
      ; kind : network_error_kind
      }
  | TimeoutError of
      { message : string
      ; phase : timeout_phase
      }
  | AcceptRejected of { reason : string }
  (** The request cannot be accepted because its transport wiring is invalid,
      such as a CLI provider without an injected subprocess transport or an
      HTTP deadline without the clock capability required to enforce it.
      Distinct from {!NetworkError} so callers can treat it as a configuration
      bug rather than a transient failure. *)
  | ProviderTerminal of
      { kind : provider_terminal_kind
      ; message : string
      }
  (** Provider reported a structured terminal condition on its
          completion stream.  Distinct from {!NetworkError} so callers
          and the agent runtime can preserve it as provider evidence rather
          than treat it as a transient network failure.

          @since 0.178.0 *)
  | ProviderFailure of
      { kind : provider_failure_kind
      ; message : string
      }
  (** Provider/runtime failure classified at the transport edge.
      Examples: model capacity exhaustion from a CLI stderr stream,
      invalid CLI policy, or a request that requires a capability the
      transport cannot provide. *)

(** Diagnostic rendering only. Consumers must branch on [provider_failure_kind]
    directly and never parse this string. *)
val provider_failure_kind_to_string : provider_failure_kind -> string

val provider_failure_to_string : kind:provider_failure_kind -> message:string -> string

(** Construct the canonical fail-closed transport error for a provider response
    with no thinking, text, or tool calls. Sync and streaming completion paths
    must use this helper so the typed stop reason and diagnostic stay aligned. *)
val empty_completion_error : stop_reason:Types.stop_reason -> http_error

(** Construct the canonical typed pre-dispatch rejection for an exact
    serialized request body that exceeds its resolved target limit. *)
val request_body_too_large_error : actual_bytes:int -> limit_bytes:int -> http_error

val stream_idle_state_to_label : stream_idle_state -> string
val timeout_phase_of_stream_idle_state : stream_idle_state -> timeout_phase
val timeout_phase_to_label : timeout_phase -> string

(** RFC-OAS-037: the caller-supplied knob a streaming deadline came from. A
    fired timeout names this knob so the operator tunes the budget that
    actually governed the phase, instead of always being pointed at the
    inter-token idle one. *)
type timeout_knob =
  | First_event_timeout
  | Body_timeout
  | Stream_idle_timeout

(** Parameter name of [timeout_knob], as callers spell it. *)
val timeout_knob_to_param : timeout_knob -> string

(** Which knob governs a timeout fired in [state]. For
    [Awaiting_first_event] this follows the same precedence chain that arms
    the first-event wait ([first_event_timeout] > [body_timeout] >
    [idle_timeout]); every later phase is inter-token idle by construction. *)
val governing_timeout_knob
  :  state:stream_idle_state
  -> first_event_timeout:float option
  -> body_timeout:float option
  -> idle_timeout:float option
  -> timeout_knob

(** Canonical resolution of an optional caller-owned deadline.

    [Unbounded] means no timeout was requested and therefore needs no clock.
    [Bounded] carries the exact clock and timeout supplied by the caller.

    @stability Internal *)
type 'clock explicit_deadline =
  | Unbounded
  | Bounded of 'clock * float

(** Resolve the timeout/clock contract before any operation I/O. [timeout_s =
    None] returns [Unbounded]. An explicit timeout must be finite and greater
    than zero; an invalid value or a missing clock returns the typed
    [AcceptRejected] error instead of silently disarming the deadline.

    @stability Internal *)
val resolve_explicit_deadline
  :  operation:string
  -> parameter:string
  -> clock:'clock option
  -> timeout_s:float option
  -> ('clock explicit_deadline, http_error) result

(** Run [f] unbounded or under the resolved Eio deadline. A bounded expiry
    raises [Eio.Time.Timeout]; the owning call site must project it to its
    phase-specific [TimeoutError].

    @stability Internal *)
val with_explicit_deadline : _ Eio.Time.clock explicit_deadline -> (unit -> 'a) -> 'a

(** {1 Connection cache} *)

(** Opaque reusable connection cache.

    A cache holds idle Eio transport connections keyed by origin
    [(scheme, host, port)]. It is bound to the [sw] passed to
    {!create_cache}; all cached connections are closed when that switch is
    released. An optional eviction fiber reaps entries that have been
    idle longer than [idle_ttl_seconds].

    @since 0.208.0 *)
type cache

(** Statistics snapshot for observability. *)
type cache_stats =
  { idle_per_host : (string * int) list
  ; total_idle : int
  ; reuse_count_total : int
  ; create_count_total : int
  }

(** Create a connection cache.

    [max_idle_per_host] caps the number of idle connections kept per origin.
    [idle_ttl_seconds] is the maximum time an idle connection is kept.
    [clock], if supplied, drives the background eviction fiber.

    @since 0.208.0 *)
val create_cache
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> ?max_idle_per_host:int
  -> ?idle_ttl_seconds:float
  -> unit
  -> cache

(** Snapshot of current cache statistics. *)
val cache_stats : cache -> cache_stats

(** GET a URL synchronously, returning the full response.
    Returns [(status_code, body_string)] on success.

    Without [cache], the connection is closed immediately after the
    request completes. With [cache], the connection is bound to the
    cache's switch and parked back in the cache on success for reuse.

    When [cache] is supplied the [connection: close] request header is
    omitted so HTTP keep-alive can work.

    The entire operation (connect + response + body read) is bounded only when
    [timeout_s] is explicitly supplied. Enforcing that deadline also requires
    [clock]; supplying [timeout_s] without [clock] returns [AcceptRejected]. A
    timeout owned by this wrapper surfaces as
    [TimeoutError { phase = Http_operation; _ }] which is classified as
    retryable by {!Retry.is_retryable}. *)
val get_sync
  :  ?cache:cache
  -> ?clock:_ Eio.Time.clock
  -> ?timeout_s:float
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> url:string
  -> headers:(string * string) list
  -> unit
  -> (int * string, http_error) result

(** POST JSON body synchronously, returning the full response.
    Returns [(status_code, body_string)] on success.

    Without [cache], the connection is closed immediately after the
    request completes. With [cache], the connection is bound to the
    cache's switch and parked back in the cache on success for reuse.

    When [cache] is supplied the [connection: close] request header is
    omitted so HTTP keep-alive can work.

    The entire operation is bounded only when [timeout_s] is explicitly
    supplied. Enforcing that deadline also requires [clock]; supplying
    [timeout_s] without [clock] returns [AcceptRejected]. A timeout owned by
    this wrapper surfaces as [TimeoutError { phase = Http_operation; _ }]. *)
val post_sync
  :  ?cache:cache
  -> ?clock:_ Eio.Time.clock
  -> ?timeout_s:float
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> url:string
  -> headers:(string * string) list
  -> body:string
  -> unit
  -> (int * string, http_error) result

(** Observable phase of a single HTTP dispatch.

    [Before_dispatch] covers request validation, URL resolution, and connection
    establishment before the HTTP request is submitted. [Dispatch_started]
    begins immediately before the sole [Cohttp_eio.Client.post] call.
    [Response_received] begins once response headers and status are available;
    response-body reads happen in this phase. *)
type one_dispatch_phase =
  | Before_dispatch
  | Dispatch_started
  | Response_received

type response_header_evidence

(** Stable fingerprint of canonical, redacted response-header evidence. Header
    names, values, and provider-specific semantics are deliberately opaque. *)
val response_header_evidence_fingerprint : response_header_evidence -> string

(** Raw response from {!post_sync_once}. No provider-specific body parsing or
    retry policy has run. *)
type raw_sync_response =
  { status : int
  ; body : string
  ; retry_after_header : float option
  }

(** Failure evidence from {!post_sync_once}. The variant makes phase/status
    combinations explicit: only a received response can carry an HTTP status. *)
type post_sync_once_error =
  | Before_dispatch_error of http_error
  | Dispatch_started_error of http_error
  | Response_received_error of
      { status : int
      ; error : http_error
      }

(** Submit exactly one HTTP POST and return the unparsed response.

    This function never retries and invokes [Cohttp_eio.Client.post] at most
    once. [headers] and [body] are forwarded without adding or removing request
    headers; callers that require [Content-Length] or [Connection] must freeze
    those headers before calling. Supplying [cache] permits connection reuse
    only and does not change the wire request.

    [connect_timeout_s] separately bounds connection establishment plus the
    request/response-header phase. [body_timeout_s] is the caller-owned total
    deadline across connection establishment, request/response headers, and
    full response-body consumption. The earlier deadline wins. Each explicit
    timeout requires [clock]. Caller-owned cancellation and a nested
    [Eio.Time.Timeout] are re-raised only after the checked-out connection has
    been closed. *)
val post_sync_once
  :  ?cache:cache
  -> ?clock:_ Eio.Time.clock
  -> ?connect_timeout_s:float
  -> ?body_timeout_s:float
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> url:string
  -> headers:(string * string) list
  -> body:string
  -> unit
  -> (raw_sync_response, post_sync_once_error) result

(** Evidence-bearing transport variant. It performs the same sole POST as
    {!post_sync_once}, while also returning opaque canonical response-header
    evidence. The public wrapper calls this function once and discards that
    evidence; neither path retries. *)
val post_sync_once_with_evidence
  :  ?cache:cache
  -> ?clock:_ Eio.Time.clock
  -> ?connect_timeout_s:float
  -> ?body_timeout_s:float
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> url:string
  -> headers:(string * string) list
  -> body:string
  -> unit
  -> (raw_sync_response * response_header_evidence, post_sync_once_error) result

(** POST JSON body for SSE/NDJSON streaming.
    Returns [Ok reader] on HTTP 200 (10 MB buffer).
    Returns [Error] on non-200 or network failure.

    The connection is bound to [sw]; prefer {!with_post_stream} to
    ensure the connection fd is released when the stream is consumed.

    [cache] is accepted for API symmetry but is currently ignored: the
    returned [Buf_read.t] outlives this function, so the client cannot
    be safely parked until consumption finishes. Use {!with_post_stream}
    for cache-aware streaming.

    Only an explicitly supplied [connect_timeout_s] bounds the connect +
    initial response headers phase. Enforcing it also requires [clock];
    supplying [connect_timeout_s] without [clock] returns [AcceptRejected].
    Body consumption through the returned reader is the caller's
    responsibility to timebox. *)
val post_stream
  :  ?cache:cache
  -> ?clock:_ Eio.Time.clock
  -> ?connect_timeout_s:float
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> url:string
  -> headers:(string * string) list
  -> body:string
  -> unit
  -> (Eio.Buf_read.t, http_error) result

(** Like {!post_stream} but manages connection lifetime internally.
    [f] receives the reader; when [f] returns the connection is closed
    and its fd is released immediately.

    When [cache] is supplied, the streaming connection is bound to the
    cache's long-lived switch and is parked back after [f] returns, so
    it can be reused across requests. [f] must consume the full response
    body; leaving unread bytes on the reader will corrupt the next reuse.

    An explicitly supplied [connect_timeout_s] bounds only the connect +
    initial response headers phase and requires [clock]. Supplying the
    deadline without [clock] returns [AcceptRejected]; a stall with both
    supplied surfaces as [TimeoutError { phase = Http_operation; _ }].

    Body consumption in [f] runs OUTSIDE [catch_network]. A body-phase
    [Eio.Time.Timeout] (first-token / prefill wait, inter-chunk idle)
    is therefore NOT mapped to [Http_operation] here. Stream-state-aware
    callers (see {!Complete_stream.body_logic}) catch it inside [f] and
    emit the precise phase (prefill → [First_token], inter-chunk →
    [Stream_idle]); callers that let it propagate get
    [TimeoutError { phase = Unknown_timeout; _ }] as a safe default.

    A cached connection is parked only when BOTH hold: the response body
    source itself reported end-of-file while [f] was consuming it, and the
    response says the connection may persist (HTTP version, [Connection],
    upgrade, and self-delimiting framing). EOF alone is not enough — a
    response with neither content-length nor chunked framing is delimited by
    the close itself, so its EOF means the peer went away. If [f] returns
    before EOF, or the underlying transport reaches EOF, the connection is
    closed regardless of [f]'s return value. *)
val with_post_stream
  :  ?cache:cache
  -> ?clock:_ Eio.Time.clock
  -> ?connect_timeout_s:float
  -> ?on_response_status:(int -> unit)
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> url:string
  -> headers:(string * string) list
  -> body:string
  -> f:(Eio.Buf_read.t -> 'a)
  -> unit
  -> ('a, http_error) result

(** Read SSE-formatted lines from a reader.

    Field lines are parsed per the W3C EventSource grammar
    ("name[:[ ]value]" — at most one leading space stripped from the
    value), so both [data: x] and [data:x] dispatch. [event:] sets the
    current event type; [data:] payloads (including empty ones) go to
    [on_data]; [id]/[retry] and unknown field names are ignored; a
    blank line resets the event type. Returns normally on
    [End_of_file].

    [on_data] runs OUTSIDE the idle-timeout window: it must not block —
    a parked handler silences the idle deadline for the whole stream.

    When both [clock] and [idle_timeout] are supplied, raises
    [Eio.Time.Timeout] if no line arrives within [idle_timeout]
    seconds. The deadline resets after each successful meaningful
    line, so this bounds inter-event idle — not total stream
    duration. SSE keepalive comments (lines starting with [:]) are
    skipped inside the same timeout window — they do NOT reset the
    deadline, so a stream of pure keepalives still trips
    [idle_timeout]. Supplying [idle_timeout] WITHOUT [clock] raises
    [Invalid_argument]: that combination used to silently disarm the
    deadline. Wrapped by {!with_post_stream} the timeout should be
    caught by the caller and surfaced as
    [TimeoutError { phase = Stream_idle state; _ }] so downstream
    policy can see which stream state stalled.

    RFC-OAS-037: [first_event_timeout], when supplied (with [clock]),
    bounds the wait for the FIRST meaningful line — the time-to-first-event
    (TTFT / prefill) window — separately from [idle_timeout], which arms
    only AFTER the first meaningful line for inter-token idle. A silent
    prefill on a large context is slow-but-alive, not a hang, so it must not
    be cut by the short [idle_timeout] value. A "meaningful line" here is a
    genuine [data] field, and only that. An [event] field selects the dispatch
    type but carries no payload, and a bare blank line is only a dispatch
    delimiter: neither ends the first-event wait. Ending it on either would
    replace the caller's first-event bound with the shorter inter-token one
    before any provider data arrived — and when only [first_event_timeout] is
    wired, it would leave the read unarmed entirely.
    The effective bound is resolved from caller-supplied values only, in the
    order [first_event_timeout] > [body_timeout] (the caller's total body
    budget) > [idle_timeout] (the pre-RFC bound, kept so callers that wired
    only an idle deadline keep their previous behaviour). With none of the
    three supplied the first-event wait stays unarmed, exactly as before this
    change: this function never invents a deadline of its own. Inter-token
    idle still guards once the stream produces. Supplying
    [first_event_timeout] or [body_timeout] WITHOUT [clock] raises
    [Invalid_argument] (same silent-disarm guard as [idle_timeout]). *)
exception
  Sse_event_too_large of
    { actual_bytes : int
    ; limit_bytes : int
    }
(** Raised before an SSE event payload exceeds [max_event_bytes]. *)

(** [max_event_bytes] bounds the JOINED payload of a single event, defaulting
    to the shared response-body limit. Per-line size is already bounded by the
    reader's own [max_size]; the multi-line join accumulates outside that
    bound, so without this a provider that never sends the blank dispatch
    boundary grows the accumulator without limit.

    The armed deadline is anchored to the last payload-bearing line, not to the
    last line read: comments, [id]/[retry]/unknown fields and bare delimiters
    do not renew it, so a provider cannot hold the stream open by emitting one
    ignorable line per budget. *)

val read_sse
  :  ?clock:_ Eio.Time.clock
  -> ?idle_timeout:float
  -> ?first_event_timeout:float
  -> ?body_timeout:float
  -> ?max_event_bytes:int
  -> reader:Eio.Buf_read.t
  -> on_data:(event_type:string option -> string -> unit)
  -> unit
  -> unit

(** Read NDJSON-formatted lines from a reader (one JSON object per
    line). Blank lines are skipped so a trailing newline does not
    yield an empty payload. Returns normally on [End_of_file].

    When both [clock] and [idle_timeout] are supplied, raises
    [Eio.Time.Timeout] if no line arrives within [idle_timeout]
    seconds. The deadline resets after each successful line, so this
    bounds inter-line idle — not total stream duration. Supplying
    [idle_timeout] WITHOUT [clock] raises [Invalid_argument] (silent
    disarm removed). The raised timeout should be caught by the caller
    and surfaced as [TimeoutError { phase = Stream_idle state; _ }] so
    downstream policy can see which stream state stalled.

    RFC-OAS-037: [first_event_timeout], when supplied (with [clock]),
    bounds the wait for the FIRST line — the time-to-first-event (TTFT /
    prefill) window — separately from [idle_timeout], which arms only AFTER
    the first line for inter-token idle. A leading blank line does NOT end the
    first-event wait. Omitting [first_event_timeout] falls back to
    [body_timeout], then to [idle_timeout]; with none supplied the wait stays
    unarmed, as before this change. Inter-token idle still guards once the
    stream produces. Supplying [first_event_timeout] or [body_timeout] WITHOUT
    [clock] raises [Invalid_argument]. *)
val read_ndjson
  :  ?clock:_ Eio.Time.clock
  -> ?idle_timeout:float
  -> ?first_event_timeout:float
  -> ?body_timeout:float
  -> reader:Eio.Buf_read.t
  -> on_line:(string -> unit)
  -> unit
  -> unit

(** [true] when the error indicates local resource exhaustion
    (ephemeral port depletion, FD limit).  Cascading to another
    provider cannot help — the bottleneck is the local machine. *)
val is_local_resource_exhaustion : http_error -> bool

(** Parse an HTTP [Retry-After] header value (RFC 9110 S10.2.3) into a
    delay in seconds. Accepts either grammar the spec allows:
    - [delay-seconds]: a non-negative integer, returned as-is.
    - [HTTP-date] (IMF-fixdate, e.g. ["Sun, 06 Nov 1994 08:49:37 GMT"]):
      converted to a delay relative to [now] (a Unix timestamp in
      seconds); a date at or before [now] yields [0.0] rather than a
      negative delay.

    Obsolete HTTP-date forms (RFC 850, asctime) and any value that is
    neither a bare non-negative integer nor IMF-fixdate are malformed and
    return [None]. Never raises. *)
val parse_retry_after_seconds : now:float -> string -> float option

(** Inject ["stream": true] into a JSON body string.
    Any caller-supplied [stream] is replaced to avoid duplicate object keys. *)
val inject_stream_param : string -> string

(** Inject [{"stream_options": {"include_usage": true}}] into a JSON body
    string. OpenAI-compatible providers omit token usage from streaming
    responses unless this flag is set. Use only for OpenAI-compatible
    kinds; native-usage providers (Anthropic, Ollama, Gemini) must not
    receive it. Any caller-supplied [stream_options] is replaced to avoid
    double-injection; a non-object or unparseable body is returned
    unchanged. *)
val inject_stream_options_include_usage : string -> string

(** Inject both ["stream": true] and [{"stream_options": {"include_usage": true}}]
    in a single parse/serialize pass. Byte-identical to
    [inject_stream_param body |> inject_stream_options_include_usage] (proven by
    a parity test), but parses and serializes the body once instead of twice.
    For the OpenAI-compatible streaming path that needs both fields (GLM, Kimi,
    DashScope, OpenAI_compat) this removes one full Yojson parse and one full
    [Yojson.Safe.to_string] of the request body per turn. Native-usage
    providers (Anthropic, Ollama, Gemini) should keep using
    [inject_stream_param] (stream only). *)
val inject_stream_and_options : string -> string
