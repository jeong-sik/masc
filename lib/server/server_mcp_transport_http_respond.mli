(** Server_mcp_transport_http_respond — HTTP MCP error / not-ready /
    rate-limit response factories.

    All public factories take a {!Server_mcp_transport_http_types.deps}
    capability record (origin extraction + CORS headers + auth checks)
    and an [Httpun.Reqd.t] one-shot continuation.  None of the factories
    raise; each writes a single response and the caller is expected to
    finish handling the request.

    {1 Re-exports}

    {!mcp_headers} and {!json_headers} are re-exported from
    {!Server_mcp_transport_http_headers} as a stable seam so dependent
    callers (tests, sibling transport modules) can keep importing the
    same operator-visible header set without depending on the headers
    module directly.  The pair is documented here as the canonical
    "MCP envelope header" producer. *)

val mcp_headers : string -> string -> (string * string) list
(** [mcp_headers session_id protocol_version] returns the two MCP
    envelope headers ([mcp-session-id], [mcp-protocol-version]) used
    by every response in this module.  Order is fixed for grep
    stability in operator dumps. *)

val json_headers :
  deps:Server_mcp_transport_http_types.deps ->
  string ->
  string ->
  string ->
  (string * string) list
(** [json_headers ~deps session_id protocol_version origin] returns
    [content-type: application/json] + the {!mcp_headers} pair +
    [deps.cors_headers origin].  Used by every JSON-bodied response in
    this module so a future "rebrand the json content type" change
    must touch one site. *)

val json_headers_without_session_id :
  deps:Server_mcp_transport_http_types.deps ->
  string ->
  string ->
  (string * string) list
(** Sessionless JSON response headers for rejecting an unknown
    client-supplied [Mcp-Session-Id]. *)

val respond_not_ready :
  deps:Server_mcp_transport_http_types.deps ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  unit
(** [respond_not_ready ~deps request reqd] writes a JSON-RPC 2.0 error
    response with code [-32002], HTTP status [503 Service Unavailable],
    and a [retry-after: 2] header pinned at 2 seconds.  The literal
    message "Server is starting up, not ready yet" is part of the
    operator contract — startup probes grep on the exact string.

    Unlike the other factories, this response uses
    [content-type: application/json] directly (not the {!json_headers}
    builder) because [session_id] / [protocol_version] are not
    available before the runtime is up.  The asymmetry is intentional —
    a future "always go through json_headers" refactor would require
    promoting both to optional and is deferred. *)

val respond_sse_register_error :
  deps:Server_mcp_transport_http_types.deps ->
  origin:string ->
  protocol_version:string ->
  Httpun.Reqd.t ->
  string ->
  unit
(** [respond_sse_register_error ~deps ~origin ~protocol_version reqd msg]
    responds 404 without [Mcp-Session-Id] for an SSE GET register whose
    session validation failed (unknown/expired). Sent before the 200 stream
    is opened so MCP clients re-run [initialize] without a session header
    instead of retrying the same stale session forever. Mirrors the POST
    JSON-RPC unknown-session path ([server_mcp_transport_http.ml]). *)

val respond_sse_rate_limited :
  deps:Server_mcp_transport_http_types.deps ->
  origin:string ->
  session_id:string ->
  protocol_version:string ->
  reason:Sse_reject_reason.t ->
  retry_after_s:float ->
  Httpun.Reqd.t ->
  unit
(** [respond_sse_rate_limited ~deps ~origin ~session_id
    ~protocol_version ~reason ~retry_after_s reqd] writes a JSON
    response with HTTP status [429 Too Many Requests] for SSE
    connection rate-limit decisions.

    Two contractual normalisations on [retry_after_s]:

    - JSON body: floored to [0.001s] (1 ms) so the consumer never sees
      a zero or negative duration.
    - HTTP [retry-after] header: ceiled to next integer second and
      floored to [1s].  HTTP headers are integer seconds; rounding up
      preserves the rate-limiter's intent (do not retry sooner).

    The asymmetry between body float and header int is deliberate —
    the body is for SSE clients that can use sub-second precision, the
    header is for HTTP middleboxes (proxies / curl --retry) that
    cannot.  A future "let's just put the float in the header"
    refactor would silently change middlebox behaviour.

    The error code in the body is the literal string
    [sse_connection_rate_limited]; dashboards / log greps depend on
    the exact spelling. *)

val error_body :
  ?id:Yojson.Safe.t ->
  ?data:Yojson.Safe.t ->
  code:Mcp_error_code.t ->
  string ->
  Yojson.Safe.t
(** [error_body ?id ?data ~code msg] builds a JSON-RPC 2.0 error
    object suitable for either a stand-alone response body or
    embedding in an SSE batch / multi-response array. Splitting it
    out makes the wire shape diffable and testable without
    instantiating an [Httpun.Reqd.t].

    Defaults: [id = `Null] (per JSON-RPC 2.0 §5.1), no [data] field.

    Used internally by {!respond_mcp_error}; exposed here for callers
    that build SSE batch frames with any {!Mcp_error_code.t}. *)

val respond_mcp_error :
  ?extra_headers:(string * string) list ->
  ?data:Yojson.Safe.t ->
  ?id:Yojson.Safe.t ->
  deps:Server_mcp_transport_http_types.deps ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  session_id:string ->
  protocol_version:string ->
  code:Mcp_error_code.t ->
  string ->
  unit
(** [respond_mcp_error ?extra_headers ?data ?id ~deps request reqd
    ~session_id ~protocol_version ~code msg] writes a single JSON-RPC
    2.0 error response derived from a typed {!Mcp_error_code.t}. This
    is the {b RFC-0098 SSOT} for transport-boundary error envelopes;
    new call sites SHOULD use this in preference to the per-code
    factories below.

    Wire shape: [{"jsonrpc":"2.0","id":<id|null>,"error":{
      "code":Mcp_error_code.to_wire_code code,
      "message":msg,
      "data":<data when supplied>}}]

    HTTP status comes from {!Mcp_error_code.to_http_status}; the
    transport cannot drift from envelope semantics. Per-code header
    fixups apply automatically:

    - [Auth_error] adds [www-authenticate: Bearer] (pinned for MCP
      client SDKs that key off the literal challenge string).
    - [Not_ready] adds [retry-after: 2] (pinned for startup probes).
    - [Backpressure_shed] adds [retry-after: 1].

    [extra_headers] are prepended; {!json_headers} append.  The
    function never raises; response writes go through the module's
    guarded response helper. *)
