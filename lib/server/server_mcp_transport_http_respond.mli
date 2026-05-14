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

val respond_mcp_auth_error :
  ?extra_headers:(string * string) list ->
  deps:Server_mcp_transport_http_types.deps ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  session_id:string ->
  protocol_version:string ->
  string ->
  unit
(** [respond_mcp_auth_error ?extra_headers ~deps request reqd
    ~session_id ~protocol_version msg] writes a JSON-RPC 2.0 error
    response with code [-32001] and HTTP status [401 Unauthorized].

    The response always carries [www-authenticate: Bearer]; this is
    pinned because the MCP client SDKs key off the literal challenge
    string when deciding whether to re-prompt for a token.  A future
    "support digest auth" change must extend the contract explicitly.

    [extra_headers] are prepended (operator-visible HTTP headers),
    {!json_headers} append.  The function never raises. *)

val respond_mcp_internal_error :
  ?extra_headers:(string * string) list ->
  deps:Server_mcp_transport_http_types.deps ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  session_id:string ->
  protocol_version:string ->
  string ->
  unit
(** [respond_mcp_internal_error ?extra_headers ~deps request reqd
    ~session_id ~protocol_version msg] writes a JSON-RPC 2.0 error
    response with code [-32603] (the standard "Internal error" slot)
    and HTTP status [500 Internal Server Error].

    Used as the catch-all for runtime failures the transport cannot
    classify more precisely.  The wording of [msg] is operator-visible
    in JSON bodies — callers should keep it stable across builds so
    grep alerts remain valid. *)

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

val mcp_internal_error_json : ?id:Yojson.Safe.t -> string -> Yojson.Safe.t
(** [mcp_internal_error_json ?id msg] returns a JSON-RPC 2.0 error
    object with code [-32603] (matching {!respond_mcp_internal_error})
    suitable for embedding in an SSE batch frame or a multi-response
    array.  When [id] is omitted, the field is set to [`Null] (per
    JSON-RPC 2.0 §5.1 — error responses must echo back the request id
    or [null] when it cannot be parsed). *)
