(** HTTP client for LLM provider endpoints.

    Eio + cohttp-eio with TLS via {!Api_common.make_https_result}.
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

(** What a stream was producing when it went idle: the state its last
    named production left it in. Transport-generic: provider parsers
    translate chunks into AGENT_CORE SSE events first, and the evidence
    records only the broad activity. *)
type stream_production =
  | Streaming_answer
  | Streaming_thinking
  | Streaming_tool_call
  | Streaming_heartbeat
  | Streaming_substrate
  | Streaming_done
  | Streaming_unknown
[@@deriving yojson, show]

(** Where a stream reader stands before its first output: waiting for the
    first frame, waiting for a delta after a frame that carried none, or on
    a production a frame named before any output arrived (a heartbeat, a
    block opening). Read for the message a first-token timeout carries; the
    phase of such a timeout is {!First_token}, never {!Stream_idle}, which
    is why {!timeout_phase} takes a {!stream_production}. *)
type stream_idle_state =
  | Awaiting_first_event
  | Awaiting_first_delta
  | Producing of stream_production
[@@deriving yojson, show]

(** Typed timeout source.

    [NetworkError { kind = Timeout; _ }] still exists for low-level OS or
    legacy timeouts.  New call-site-owned deadlines should surface as
    {!TimeoutError} with one of these phases so downstream policy can
    distinguish scheduler queueing, first-token wait, streaming idleness,
    whole-call wall clocks, capacity backpressure, transport/body deadlines,
    CLI stdout idleness, and generic caller budgets. *)
type timeout_phase =
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
  | Stream_idle of stream_production
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
      data; AGENT_CORE does not infer rate-limit or retry semantics from it. *)
  | Provider_interrupted
  (** The provider accepted the request, began a choice and ended it with an
      error it did not describe: the choice's finish reason says [error]
      ({!Stop_reason_wire.is_provider_error_finish}) and no error object
      arrived anywhere in the response. Distinct from
      [Provider_reported_error], which has an envelope to read a type or a
      status from, and from [Provider_wire_error], where what arrived breaks
      the declared wire contract. The generation stopped part-way for a
      reason the provider kept to itself. *)
  | Response_body_too_large of { limit_bytes : int }
  (** The provider response exceeded the explicit in-memory parser boundary.
      The connection is closed immediately; AGENT_CORE never drains an unbounded
      remainder merely to preserve connection reuse. *)
  | Empty_completion of { stop_reason : Types.stop_reason }
  (** agent-core boundary: a 200 with no deliverable content (no thinking/text/tool_calls).
      The typed stop reason is preserved so downstream policy can distinguish,
      for example, [MaxTokens] from [EndTurn] without parsing diagnostics. *)
  | Context_overflow of { limit : int option }
  (** agent-core boundary: the provider reported in its error envelope that the request
      exceeded the model context window (e.g. glm code 1261 "Prompt exceeds
      max length"). Distinct from an empty completion whose
      [stop_reason] is [ContextWindowExceeded] (the same condition reported
      through a 200). Retrying or rotating replays the same oversized prompt;
      only the consumer's context recovery (compaction/shrink) can make
      progress. [limit] is the provider-reported token limit when the
      envelope carries one. *)
  | Repeating_generation of
      { shape : Types.repeating_shape
      ; occurrences : int
      ; unit_bytes : int
      }
      (** The model's generation repeated one unit — a paragraph of the
          answer, or a reasoning cycle — past the threshold and this client
          ended the stream. Bytes and framing were fine, so this is not a
          [Provider_wire_error]: what failed is the model, and the same model
          reached through another provider repeats the same way. *)
  | Unknown_provider_failure of { reason : string option }

(** The body of a refusing response. [Received] is what the provider sent,
    empty when it sent nothing. [Not_received_in_window] is a body the
    caller's own window closed on before it arrived: the status line and its
    headers are the answer, and the reason they carried is unread. The two
    are not the same fact -- a provider code that names a recoverable cause
    is absent from one and unknown in the other -- so they are not the same
    value. *)
type refusal_body =
  | Received of string
  | Not_received_in_window

(** The text a refusal carried, empty when none arrived. For rendering; a
    decision reads the variant. *)
val refusal_body_text : refusal_body -> string

(** Transport-level error. *)
type http_error =
  | HttpError of
      { code : int
      ; body : refusal_body
      ; retry_after_header : float option
        (** Parsed [Retry-After] response header (RFC 9110 S10.2.3), resolved
          to a delay in seconds relative to when the response was observed.
          [None] when the header was absent or malformed. Every synchronous
          path now carries response headers, so an absent value means the
          response really had none.
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

(** Shared transport-edge exception classification. Exact-output measurement
    uses the same typed Unix/Eio/TLS facts as ordinary provider requests.
    [None] means the exception is not a known transport failure; in particular
    caller cancellation and reserved exceptions must still propagate. *)
val classify_network_exn : exn -> http_error option

(** Diagnostic rendering only. Consumers must branch on [provider_failure_kind]
    directly and never parse this string. *)
val provider_failure_kind_to_string : provider_failure_kind -> string

val provider_failure_to_string : kind:provider_failure_kind -> message:string -> string

(** Construct the canonical fail-closed transport error for a provider response
    with no thinking, text, or tool calls. Sync and streaming completion paths
    must use this helper so the typed stop reason and diagnostic stay aligned. *)
val empty_completion_error : stop_reason:Types.stop_reason -> http_error

val stream_production_to_label : stream_production -> string
val stream_idle_state_to_label : stream_idle_state -> string
val timeout_phase_to_label : timeout_phase -> string

(** Agent Core contract: the caller-supplied knob a streaming deadline came from. A
    fired timeout names this knob so the operator tunes the budget that
    actually governed the phase, instead of always being pointed at the
    inter-token idle one. *)
type timeout_knob =
  | First_event_timeout
  | Body_timeout
  | Stream_idle_timeout

(** Parameter name of [timeout_knob], as callers spell it. *)
val timeout_knob_to_param : timeout_knob -> string

(** Which budget the reader had armed when a deadline fired: the first-event
    budget until the consumer reports its first [Output], the inter-token idle
    budget after it. The consumer derives the phase from the same report it
    returned to the reader, so the knob it names cannot drift from the bound
    that fired. *)
type budget_phase =
  | Before_first_output
  | After_first_output

(** Which knob governs a timeout fired in [phase]. For
    [Before_first_output] this follows the same precedence chain that arms
    the first-event wait ([first_event_timeout] > [body_timeout] >
    [idle_timeout]); [After_first_output] is inter-token idle by
    construction. *)
val governing_timeout_knob
  :  phase:budget_phase
  -> first_event_timeout:float option
  -> body_timeout:float option
  -> idle_timeout:float option
  -> timeout_knob

(** Canonical resolution of an optional caller-owned deadline.

    [Unbounded] means no timeout was requested and therefore needs no clock.
    [Bounded] carries the exact clock and timeout supplied by the caller.

    Private: [resolve_explicit_deadline] is the only way to build one, so the
    check it makes is the only shape that exists. A [Bounded] carrying
    [infinity] reads as a deadline everywhere and bounds nothing -- an eio
    sleep of an infinite span never wakes -- and the resolver rejects it along
    with [nan] and anything not greater than zero. Consumers still match on
    the constructors; they just cannot build one.

    @stability Internal *)
type 'clock explicit_deadline = private
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

(** Run [f] unbounded or under the resolved Eio deadline. An [f] that
    finished as the deadline passed is the answer: the deadline raises
    [Eio.Time.Timeout] only when [f] had not finished, and the owning call
    site must project it to its phase-specific [TimeoutError].

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

(** Raw response from a synchronous dispatch
    ({!get_sync}, {!post_sync}, {!post_sync_once}). No provider-specific body parsing or
    retry policy has run. *)
type raw_sync_response =
  { status : int
  ; body : string
  ; retry_after_header : float option
  ; content_type : string option
        (** Raw [Content-Type] response header, trimmed, or [None] when the
          response carried none. Kept unparsed: deciding whether a body is the
          media the caller asked for belongs to the caller, not to transport. *)
  }

(** GET a URL synchronously, returning the full response.
    Returns status, body, and the response-header evidence the caller needs
    ([Retry-After], [Content-Type]) on success — the same
    {!raw_sync_response} {!post_sync} returns.

    Without [cache], the connection is closed immediately after the
    request completes. With [cache], the connection is bound to the
    cache's switch and parked back in the cache on success for reuse.

    When [cache] is supplied the [connection: close] request header is
    omitted so HTTP keep-alive can work.

    The entire operation (connect + response + body read) is bounded only when
    [timeout_s] is explicitly supplied. Enforcing that deadline also requires
    [clock]; supplying [timeout_s] without [clock] returns [AcceptRejected]. A
    timeout owned by this wrapper surfaces as
    [TimeoutError { phase = Http_operation; _ }]. *)
val get_sync
  :  ?cache:cache
  -> ?clock:_ Eio.Time.clock
  -> ?timeout_s:float
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> url:string
  -> headers:(string * string) list
  -> unit
  -> (raw_sync_response, http_error) result

(** DELETE synchronously, returning the full response — same receipt shape
    and deadline semantics as {!get_sync} over the DELETE verb. The Files API
    (RFC-0430 Phase 3) answers deletion with a JSON body even on 2xx. *)
val delete_sync
  :  ?cache:cache
  -> ?clock:_ Eio.Time.clock
  -> ?timeout_s:float
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> url:string
  -> headers:(string * string) list
  -> unit
  -> (raw_sync_response, http_error) result

(** POST JSON body synchronously, returning the full response.
    Returns status, body, and the response-header evidence the caller needs
    ([Retry-After], [Content-Type]) on success.

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
  -> (raw_sync_response, http_error) result

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

(** URI, headers, and body admitted before transport effects begin. The URI has
    an explicit HTTP(S) scheme, non-empty host, and resolved port; callers cannot
    reopen those optional URI fields after this boundary. *)
type validated_sync_request

(** Successful one-dispatch receipt. Status, body, retry evidence, and canonical
    response-header evidence stay together through downstream parsing. *)
type sync_transport_receipt =
  { response : raw_sync_response
  ; response_header_evidence : response_header_evidence
  }

(** Validate a synchronous POST request without performing DNS, connection, or
    HTTP effects. Unsupported schemes, missing hosts, invalid ports, and invalid
    headers fail before dispatch. *)
val prepare_sync_request
  :  url:string
  -> headers:(string * string) list
  -> body:string
  -> (validated_sync_request, http_error) result

(** Failure evidence from {!post_sync_once}. The variant makes phase/status
    combinations explicit: only a received response can carry an HTTP status. *)
type post_sync_once_error =
  | Before_dispatch_error of http_error
  | Dispatch_started_error of http_error
  | Response_received_error of
      { status : int
      ; error : http_error
      }

(** Execute one already-validated request. This is the effect boundary for
    callers that must observe or persist pre-dispatch evidence only after all
    request decoding has succeeded. *)
val dispatch_sync_request
  :  ?cache:cache
  -> ?clock:_ Eio.Time.clock
  -> ?connect_timeout_s:float
  -> ?body_timeout_s:float
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> validated_sync_request
  -> unit
  -> (sync_transport_receipt, post_sync_once_error) result

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
    timeout requires [clock]. A body that outruns the total deadline ends a
    successful status as [TimeoutError { phase = Wall_clock; _ }], the body
    being the answer; under a status that is not a success the answer is
    already in hand, and the response is returned with that status, its
    headers, and an empty body, the connection released and not parked.
    Caller-owned cancellation and a nested [Eio.Time.Timeout] are re-raised
    only after the checked-out connection has been closed. *)
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
    evidence in one typed receipt. The public wrapper calls this function once
    and discards that evidence; neither path retries. *)
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
  -> (sync_transport_receipt, post_sync_once_error) result

(** POST a JSON body and read the SSE/NDJSON response under a managed
    connection lifetime. [f] receives the reader; when [f] returns the
    connection is closed and its fd is released immediately.

    When [cache] is supplied, the streaming connection is bound to the
    cache's long-lived switch and is parked back after [f] returns, so
    it can be reused across requests. [f] must consume the full response
    body; leaving unread bytes on the reader will corrupt the next reuse.

    The phase before the response headers -- the connection (TCP, TLS),
    the request and the wait for the status line -- runs under the
    narrower of [connect_timeout_s] and [first_event_timeout_s]; either
    requires [clock], and a budget supplied without it returns
    [AcceptRejected]. A stall the connect budget ends surfaces as
    [TimeoutError { phase = Http_operation; _ }]; one the first-event
    budget ends surfaces as [TimeoutError { phase = First_token; _ }], the
    provider having sent no status line in the whole time allowed before a
    first token. A refusing status line is the provider's answer: its body
    is read under what the window has left, and a body that does not
    arrive in time still yields [HttpError] with the status and the
    Retry-After received and the body [Not_received_in_window], not a
    timeout. A connection handed back as the window closes is the
    connection: the window's verdict stands only when nothing had returned,
    and a connection it cut off before the handoff is closed.
    With neither budget supplied the phase is unbounded. Two steps run
    outside the window's reach: DNS resolution, in a systhread the window
    cannot cancel (a closed window is observed once the lookup returns, and
    until then the resolver's own timeout is the bound), and the trust-store
    load an https connection makes synchronously on this domain, cached
    once it succeeds and repeated by every connection while it fails; on a
    connection that loads the store the two run as one stretch and the
    window is observed after their sum. [f] receives
    [pre_header_elapsed_s], the seconds this phase took on [clock] (0
    without one), and arms what is left of the
    first-event budget on the reader ({!read_sse}, {!read_ndjson}): the
    budget is one window from the request to the first token, not one in
    front of the headers and another after them.

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
  -> ?first_event_timeout_s:float
  -> ?on_response_status:(int -> unit)
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> url:string
  -> headers:(string * string) list
  -> body:string
  -> f:(pre_header_elapsed_s:float -> Eio.Buf_read.t -> 'a)
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

    Agent Core contract: [first_event_timeout], when supplied (with [clock]),
    bounds the wait for the first event the consumer reports as [Output] —
    the time-to-first-token (prefill) window — separately from
    [idle_timeout], which arms only after that first output for inter-token
    idle. A silent prefill on a large context is slow-but-alive, not a hang,
    so it must not be cut by the short [idle_timeout] value. The reader
    cannot tell output from a provider's opening frame, so it does not try:
    the consumer returns [Continue Output] or [Continue Prelude] from
    [on_data] and the reader switches budgets on the first [Output]. A
    first-event budget from [first_event_timeout] or [body_timeout] is one
    window from the first body read to that [Output]: an [event] field, a
    bare blank line, a keepalive comment and a [Prelude] event neither end it
    nor extend it, so it bounds the whole wait for the first token, as its
    name says. Ending it on any of them would replace the caller's
    first-event bound with the shorter inter-token one before the model
    produced anything, and when only [first_event_timeout] is wired it would
    leave the read unarmed entirely; extending it on any of them would let a
    provider that never produces hold the stream open with one prelude frame
    per budget.
    The effective bound is resolved from caller-supplied values only, in the
    order [first_event_timeout] > [body_timeout] (the caller's total body
    budget) > [idle_timeout] (the pre-RFC bound, kept so callers that wired
    only an idle deadline keep their previous behaviour: it stays a gap bound
    that every payload line renews, before the first [Output] as after it).
    With none of the
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

(** What one dispatched event or line carried, as only the consumer's parser
    can tell. The reader keeps the first-event budget armed until the consumer
    reports the first [Output] and arms the inter-token idle budget after it.
    A provider's opening frame is [Prelude]: Responses sends
    [response.created] and Anthropic sends [message_start] before prefill and
    before any reasoning, so a reader that switched budgets on the first data
    line put a silent prefill under the short inter-token bound. Pings,
    structural frames and anything else that carries no token are [Prelude]
    too; a text, thinking, tool-argument or media delta is [Output]. *)
type dispatched_event =
  | Prelude
  | Output

(** What the consumer wants after one dispatched event or line, and what that
    event was.

    [Stop] ends the read loop before its next blocking read. A consumer that
    has stopped consuming must return it: otherwise the socket keeps
    delivering a body nobody reads until the provider finishes or a deadline
    fires, and the caller pays for output it discards while the connection is
    held for the whole of it. The decision is returned rather than asked for
    through a predicate so no caller can omit it.

    Both readers return [unit], so a caller cannot tell a [Stop] exit from an
    end of body. That is only safe while [Stop] means the consumer has already
    failed the response: a consumer that stopped for a benign reason — a
    terminal marker it recognised, say — would hand its accumulator a body it
    truncated on purpose and finalize it as a complete answer. Stop because
    the answer is void, not because you have enough of it. *)
type stream_continuation =
  | Continue of dispatched_event
  | Stop

(** [max_event_bytes] bounds the JOINED payload of a single event, defaulting
    to the shared response-body limit. Per-line size is already bounded by the
    reader's own [max_size]; the multi-line join accumulates outside that
    bound, so without this a provider that never sends the blank dispatch
    boundary grows the accumulator without limit.

    The armed deadline is anchored, not per read. A first-event or body budget
    is anchored at the first body read and no line moves it; the idle budget
    is anchored at the last payload-bearing line. Comments,
    [id]/[retry]/unknown fields and bare delimiters never renew a budget, so a
    provider cannot hold the stream open by emitting one ignorable line per
    budget, and a prelude frame cannot hold a first-event budget open either. *)

val read_sse
  :  ?clock:_ Eio.Time.clock
  -> ?idle_timeout:float
  -> ?first_event_timeout:float
  -> ?body_timeout:float
  -> ?max_event_bytes:int
  -> reader:Eio.Buf_read.t
  -> on_data:(event_type:string option -> string -> stream_continuation)
  -> unit
  -> unit

(** Read NDJSON-formatted lines from a reader (one JSON object per
    line). Blank lines are skipped so a trailing newline does not
    yield an empty payload. Returns normally on [End_of_file].

    When both [clock] and [idle_timeout] are supplied, raises
    [Eio.Time.Timeout] when [idle_timeout] seconds pass after the last
    non-blank line (after the first body read, before any), so this bounds
    inter-line idle, not total stream duration; a blank line does not renew
    it. Before the first [Output] a first-event or body budget governs
    instead when one is supplied (below). Supplying
    [idle_timeout] WITHOUT [clock] raises [Invalid_argument] (silent
    disarm removed). The raised timeout should be caught by the caller
    and surfaced as [TimeoutError { phase = Stream_idle state; _ }] so
    downstream policy can see which stream state stalled.

    Agent Core contract: [first_event_timeout], when supplied (with [clock]),
    bounds the wait for the first line the consumer reports as [Output] — the
    time-to-first-token (prefill) window — separately from [idle_timeout],
    which arms only after that first output for inter-token idle. A
    first-event budget from [first_event_timeout] or [body_timeout] is one
    window from the first body read to that [Output]: a blank line and a line
    reported as [Prelude] neither end it nor extend it. Omitting both falls
    back to [idle_timeout], which keeps its gap meaning; with none supplied
    the wait stays unarmed, as before this change. Inter-token idle still
    guards once the stream produces. Supplying [first_event_timeout] or
    [body_timeout] WITHOUT [clock] raises [Invalid_argument]. *)
val read_ndjson
  :  ?clock:_ Eio.Time.clock
  -> ?idle_timeout:float
  -> ?first_event_timeout:float
  -> ?body_timeout:float
  -> reader:Eio.Buf_read.t
  -> on_line:(string -> stream_continuation)
  -> unit
  -> unit

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
    OpenAI_compat) this removes one full Yojson parse and one full
    [Yojson.Safe.to_string] of the request body per turn. Native-usage
    providers (Anthropic, Ollama, Gemini) should keep using
    [inject_stream_param] (stream only). *)
val inject_stream_and_options : string -> string

(** [safe_cohttp_response_flow source] wraps a [cohttp-eio] response body flow
    to ensure that reads from the underlying flow are always performed with
    buffers of at least 64KB. This guarantees that [cohttp-eio]'s internal
    [Reader_flow] never takes its buggy partial-read branch (which slices from
    offset 0 of the chunk buffer instead of the current position, corrupting
    chunked or streaming HTTP payloads). *)
val safe_cohttp_response_flow :
  [> Eio.Flow.source_ty ] Eio.Resource.t -> [> Eio.Flow.source_ty ] Eio.Resource.t
