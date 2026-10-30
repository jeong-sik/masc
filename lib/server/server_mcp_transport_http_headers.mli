(** Server_mcp_transport_http_headers — HTTP header builders, accept
    negotiation, body-method classifier, and SSE constants for the
    MCP transport.

    Re-exported piecemeal by {!Server_mcp_transport_http} via
    [let X = Server_mcp_transport_http_headers.X] bindings, so this
    surface is the SSOT for header literals (mcp-session-id /
    mcp-protocol-version / cookie format) and SSE constants
    (retry-ms / ping interval).  Operator runbooks grep on these
    literals. *)

type deps = Server_mcp_transport_http_types.deps

(** {1 JSON-RPC body classification} *)

val body_jsonrpc_method : string -> (string * bool) option
(** [body_jsonrpc_method body_str] parses [body_str] as JSON and
    returns [Some (method_, has_id)] when it is an [`Assoc] with a
    [method] string field, [None] otherwise (parse failure or
    non-object body).  [has_id] reports whether the [id] field is
    present (used to distinguish notifications from requests). *)

(** Case-insensitive lookup of [MCP-Protocol-Version]. *)

(** Case-insensitive lookup of [Mcp-Method]. *)

(** Case-insensitive lookup of [Mcp-Name]. *)

val request_uses_stateless_protocol : Httpun.Request.t -> string -> bool
(** [true] if the HTTP header declares a known stateless revision or the body
    supplies a per-request protocol version, including an unknown one. An
    unknown version in the header also selects the per-request path. *)

val header_selects_per_request_protocol : Httpun.Request.t -> bool
(** A known stateless or unknown version in any protocol-version header must
    not inherit a legacy session before the request body is available. *)

type header_rejection =
  | Mirrored_header_mismatch of string
      (** The body parsed and disagrees with a header. The request id is
          readable, so the response echoes it. *)
  | Unreadable_body of string
      (** The body is valid JSON but not a JSON-RPC object. *)
  | Malformed_json of string
      (** The body is not valid JSON; respond with JSON-RPC parse error. *)
  | Unsupported_version of { requested : string }
      (** Not a header disagreement: this server does not speak that
          revision. Answered with [-32022] and the supported list. *)
  | Missing_required_meta of { key : string }
      (** A [_meta] field 2026-07-28 marks required on every request is
          absent or has the wrong type. The request is malformed, so it is
          answered with [-32602]. *)
  | Invalid_request_envelope of string
      (** The JSON-RPC version, fields, or request ID are invalid. *)
  | Invalid_request_meta of string
      (** Required modern metadata is ambiguous or malformed. *)

val header_rejection_body : string -> header_rejection -> string
(** Construct the rejection and correlate it to the request body. A valid
    notification has no [id]; an unreadable or invalid request has a null ID. *)

val modern_response_http_error_status :
  request:Httpun.Request.t -> body_str:string -> Yojson.Safe.t ->
  Httpun.Status.t option
(** HTTP status required for modern protocol-level JSON-RPC errors. Legacy
    responses retain their existing transport behavior. *)

val validate_2026_request_headers :
  Httpun.Request.t -> string -> (unit, header_rejection) result
(** Enforces the 2026-07-28 mirrored-header contract when a request
    opts into a stateless MCP revision. Legacy requests return [Ok ()].
    Modern requests require [MCP-Protocol-Version], matching body
    [_meta], [Mcp-Method], and, for [tools/call], [resources/read],
    and [prompts/get], matching [Mcp-Name] after decoding the MCP Base64
    sentinel. Malformed or unsafe header values and duplicate routing
    headers are rejected. *)

(** [is_initialize_method m] tests whether [m] equals the literal
    [["initialize"]].  The initialize handshake must always go over
    plain JSON, never SSE. *)

(** {1 Accept-header classification}

    The MCP spec mandates [Accept: application/json, text/event-stream]
    for streamable transports.  One opt-out remains:

    - The [x-masc-force-json] request header overrides the Accept
      negotiation entirely. *)

val classify_mcp_accept :
  Httpun.Request.t ->
  Mcp_transport_protocol.Http_negotiation.accept_mode
(** [classify_mcp_accept request] reads the [accept] header and
    returns the negotiation classification. *)

val should_use_sse_for_body :
  Httpun.Request.t ->
  string ->
  Mcp_transport_protocol.Http_negotiation.accept_mode ->
  bool
(** [should_use_sse_for_body request body_str accept_mode] returns
    [true] iff the response should stream over SSE.  Two
    short-circuits to plain JSON: the body is the [initialize]
    handshake (always JSON) OR [accept_mode <> Streamable] OR the
    Accept header does not include [text/event-stream]. *)

val request_force_json_response : Httpun.Request.t -> bool
(** [request_force_json_response request] returns [true] iff the
    [x-masc-force-json] header is set to a truthy value
    ([1]/[true]/[yes]/[on], case-insensitive, trimmed).  Header
    overrides Accept negotiation. *)

val force_json_response : bool
(** Module-init cache of the [MASC_FORCE_JSON_RESPONSE] env flag (truthy
    semantics matching {!request_force_json_response}).  Forces every
    response to plain JSON regardless of Accept negotiation. *)

(** {1 Header builders} *)

val mcp_headers : string -> string -> (string * string) list
(** [mcp_headers session_id protocol_version] returns MCP envelope
    headers. Legacy protocol revisions include [mcp-session-id] and
    [mcp-protocol-version]; stateless revisions include only
    [mcp-protocol-version]. *)

val session_cookie_header : string -> string * string
(** [session_cookie_header session_id] returns
    [("set-cookie", "mcp-session-id=<id>; Path=/; Max-Age=<day>; SameSite=Lax")].
    [Max-Age] is one day (from {!Masc_time_constants.day_int}) —
    operators relying on shorter sessions must reset cookies via
    a separate path. *)

val session_cookie_headers : string -> string -> (string * string) list
(** [session_cookie_headers protocol_version session_id] returns no
    cookie headers for stateless protocol revisions, otherwise the
    legacy {!session_cookie_header}. *)

val sse_headers :
  deps:deps -> string -> string -> string -> (string * string) list
(** [sse_headers ~deps session_id protocol_version origin] returns
    SSE response headers: [content-type] (from
    {!Http_negotiation.sse_content_type}), optional legacy session
    cookie, {!mcp_headers}, plus [deps.cors_headers origin].  Used
    by the one-shot SSE response path. *)

val sse_stream_headers :
  deps:deps -> string -> string -> string -> (string * string) list
(** [sse_stream_headers ~deps session_id protocol_version origin] is
    {!sse_headers} plus [cache-control: no-cache] and
    [connection: keep-alive].  Used for long-lived SSE streams (the
    AG-UI bridge and the per-session event stream). *)

val json_headers :
  deps:deps -> string -> string -> string -> (string * string) list
(** [json_headers ~deps session_id protocol_version origin] returns
    [content-type: application/json] + {!mcp_headers} +
    [deps.cors_headers origin].  The canonical "JSON response"
    builder used by every JSON-bodied response in the transport. *)

(** {1 SSE constants} *)

val sse_retry_ms : int
(** Pinned at [3000] (3 seconds).  The [retry:] field in SSE prime
    events tells the EventSource client how long to wait before
    reconnecting after a transport error.  3 s balances transient-
    glitch recovery against tight-loop reconnect storms. *)

val sse_prime_event : unit -> string
(** [sse_prime_event ()] returns the SSE prime frame
    [["retry: <sse_retry_ms>\n\n"]]. It deliberately carries no [id]: a
    transport-only prime is absent from the replay store and therefore cannot
    advance the client's durable replay cursor. *)

val sse_comment_with_retry : comment:string -> string
(** [sse_comment_with_retry ~comment] returns an SSE comment frame
    [[": <comment>\nretry: <sse_retry_ms>\n\n"]].  Stream priming sites
    (presence, activity) use this so their reconnect interval stays sourced
    from {!sse_retry_ms} instead of an inlined literal. *)

val sse_ping_interval_s : float
(** Pinned at [30.0] seconds.  Ping fibers use this interval to
    write the SSE comment frame [": ping\n\n"] so middleboxes do
    not idle out the connection.  Matches the same constant
    duplicated in {!Server_mcp_transport_http_agui} (the duplicate
    is intentional — see that module's contract). *)

type last_event_id_error =
  | Malformed_last_event_id
  | Negative_last_event_id
(** A malformed [Last-Event-ID] header is a request error, not an
    absent replay cursor. *)

val last_event_id_error_to_string : last_event_id_error -> string

val get_last_event_id :
  Httpun.Request.t -> (int option, last_event_id_error) result
(** [get_last_event_id request] parses the [last-event-id] header.
    [Ok None] means that the header is absent. A present header that is not a
    non-negative integer is returned as [Error] so callers cannot silently
    restart replay from the origin. *)
