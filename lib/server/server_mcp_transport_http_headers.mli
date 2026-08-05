(** Server_mcp_transport_http_headers — HTTP header builders, accept
    negotiation, body-method classifier, and SSE constants for the
    MCP transport.

    Re-exported piecemeal by {!Server_mcp_transport_http} via
    [let X = Server_mcp_transport_http_headers.X] bindings, so this
    surface is the SSOT for the MCP protocol-version header and SSE constants
    (retry-ms / ping interval).  Operator runbooks grep on these
    literals. *)

type deps = Server_mcp_transport_http_types.deps

(** {1 JSON-RPC body classification} *)

val is_http_error_response : Yojson.Safe.t -> bool
(** [is_http_error_response json] returns [true] for transport-level
    JSON-RPC failures: an [id = null] Parse/Invalid Request error, or
    a Method Not Found error for any request id. Used
    to distinguish "request the server could not parse" from
    business-logic errors when deciding whether to attach a
    legacy-accept warning header. *)

val is_method_not_found_response : Yojson.Safe.t -> bool

val request_runtime_result : deps -> (Server_mcp_transport_http_types.runtime, string) result
(** [request_runtime_result deps] is a thin wrapper for
    [deps.get_runtime_result ()] — kept as a binding so the call
    site is greppable across the transport. *)

val body_jsonrpc_method : string -> (string * bool) option
(** [body_jsonrpc_method body_str] parses [body_str] as JSON and
    returns [Some (method_, has_id)] when it is an [`Assoc] with a
    [method] string field, [None] otherwise (parse failure or
    non-object body).  [has_id] reports whether the [id] field is
    present (used to distinguish notifications from requests). *)

val request_protocol_version_header : Httpun.Request.t -> string option
val jsonrpc_id_or_null : string -> Yojson.Safe.t
(** Returns the exact valid string or integer JSON-RPC id from a request body,
    including integers represented by [`Intlit], and [`Null] otherwise. *)

val unsupported_protocol_version_header : Httpun.Request.t -> string option
val unsupported_protocol_version_error_body :
  ?id:Yojson.Safe.t -> string -> string
(** Case-insensitive lookup of [MCP-Protocol-Version]. *)

val request_method_header : Httpun.Request.t -> string option
(** Case-insensitive lookup of [Mcp-Method]. *)

val request_name_header : Httpun.Request.t -> string option
(** Case-insensitive lookup of [Mcp-Name]. *)

val validate_2026_request_headers :
  Httpun.Request.t -> string -> (unit, string) result
(** Enforces the 2026-07-28 mirrored-header contract. Requests require
    [MCP-Protocol-Version], matching body
    [_meta], [Mcp-Method], and, for [tools/call], [resources/read],
    and [prompts/get], matching [Mcp-Name]. Malformed JSON is left to the
    JSON-RPC parser so it can emit the canonical parse error. *)

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
  Mcp_transport_protocol.Http_negotiation.accept_mode ->
  bool
(** [should_use_sse_for_body request accept_mode] returns
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
    response to plain JSON regardless of Accept negotiation.  The retired
    [MCP_FORCE_JSON_RESPONSE] spelling is ignored with a one-time warning
    (masc#25123 Wave 2). *)

(** {1 Header builders} *)

val mcp_headers : string -> (string * string) list
(** Returns the current MCP protocol-version response header. *)

val sse_headers :
  deps:deps -> string -> string -> (string * string) list

val sse_stream_headers :
  deps:deps -> string -> string -> (string * string) list

val json_headers :
  deps:deps -> string -> string -> (string * string) list

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
