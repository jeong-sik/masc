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

val is_http_error_response : Yojson.Safe.t -> bool
(** [is_http_error_response json] returns [true] when [json] is a
    JSON-RPC 2.0 response object with [id = null] AND [error.code]
    in [-32700] (Parse error) / [-32600] (Invalid Request).  Used
    to distinguish "request the server could not parse" from
    business-logic errors when deciding whether to attach a
    legacy-accept warning header. *)

val request_runtime_result : deps -> (Server_mcp_transport_http_types.runtime, string) result
(** [request_runtime_result deps] is a thin wrapper for
    [deps.get_runtime_result ()] — kept as a binding so the call
    site is greppable across the transport. *)

type body_jsonrpc_method_error =
  | Body_jsonrpc_method_parse_error of string

val body_jsonrpc_method_error_to_string : body_jsonrpc_method_error -> string

val body_jsonrpc_method_result
  :  string
  -> ((string * bool) option, body_jsonrpc_method_error) result
(** [body_jsonrpc_method_result body_str] parses [body_str] as JSON and
    returns [Ok (Some (method_, has_id))] for JSON-RPC request/notification
    objects, [Ok None] for valid JSON without a string [method], and
    [Error] for invalid JSON. *)

val body_jsonrpc_method : string -> (string * bool) option
(** [body_jsonrpc_method body_str] parses [body_str] as JSON and
    returns [Some (method_, has_id)] when it is an [`Assoc] with a
    [method] string field, [None] otherwise. Invalid JSON is logged before
    this compatibility fallback. [has_id] reports whether the [id] field is
    present (used to distinguish notifications from requests). *)

val request_protocol_version_header : Httpun.Request.t -> string option
(** Case-insensitive lookup of [MCP-Protocol-Version]. *)

val request_method_header : Httpun.Request.t -> string option
(** Case-insensitive lookup of [Mcp-Method]. *)

val request_name_header : Httpun.Request.t -> string option
(** Case-insensitive lookup of [Mcp-Name]. *)

val request_uses_stateless_protocol : Httpun.Request.t -> string -> bool
(** [true] iff either the HTTP protocol-version header or body
    per-request [_meta] declares a stateless MCP revision. *)

type body_required_name_error =
  | Body_required_name_parse_error of string

val body_required_name_error_to_string : body_required_name_error -> string

val body_required_name_for_method_result
  :  string
  -> string
  -> (string option, body_required_name_error) result
(** [body_required_name_for_method_result body_str method_] extracts the
    request-name field required by the mirrored-header contract:
    [params.name] for [tools/call] and [prompts/get], [params.uri] for
    [resources/read]. Methods without a required name return [Ok None].
    Invalid JSON returns [Error]. *)

val validate_2026_request_headers :
  Httpun.Request.t -> string -> (unit, string) result
(** Enforces the 2026-07-28 mirrored-header contract when a request
    opts into a stateless MCP revision. Legacy requests return [Ok ()].
    Modern requests require [MCP-Protocol-Version], matching body
    [_meta], [Mcp-Method], and, for [tools/call], [resources/read],
    and [prompts/get], matching [Mcp-Name]. *)

val is_initialize_method : string -> bool
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
(** Module-init cache of [MASC_FORCE_JSON_RESPONSE] OR
    [MCP_FORCE_JSON_RESPONSE] env flags (truthy semantics matching
    {!request_force_json_response}).  Either flag forces every
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
    [["retry: <sse_retry_ms>\nid: <next>\n\n"]] with a fresh id
    from {!Sse.next_id}.  The trailing double-newline is the SSE
    frame terminator — required by the spec. *)

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

val get_last_event_id : Httpun.Request.t -> int option
(** [get_last_event_id request] reads the [last-event-id] header
    and parses it as an integer.  Returns [None] when the header
    is absent or non-integer.  Used to drive event replay on SSE
    reconnect. *)
