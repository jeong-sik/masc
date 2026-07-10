(** Server_mcp_transport_http_session — MCP HTTP session state +
    header / cookie / query-param helpers.

    Per-session protocol-version and tool-profile registries
    plus a small library of header / cookie / query parsing
    helpers used by the MCP HTTP transport.

    `include`'d / `open`'d by sibling modules
    (`server_mcp_transport_http_protocol`, etc.) — every top-
    level binding flows through.

    {1 Protocol versioning} *)

val mcp_protocol_versions : string list
(** Alias over {!Mcp_transport_protocol.supported_protocol_versions}.
    Pinned at the contract seam — runbooks reference the list
    by name when documenting client compatibility. *)

val mcp_protocol_version_default : string
(** Alias over {!Mcp_transport_protocol.default_protocol_version}. *)

val is_valid_protocol_version : string -> bool

(** {1 Per-session state}

    Atomic [SMap.t] registries keyed by session id store
    per-session protocol version, tool profile, and owner identity.  All
    accessors below are thread-safe via internal CAS loops. *)

val remember_protocol_version :
  ?otel_transport_context:Otel_dispatch_hook.transport_context ->
  string -> string -> unit
(** [remember_protocol_version session_id version] records the
    version when [is_valid_protocol_version version] is [true];
    silently no-ops on unknown versions (the upstream caller is
    expected to have validated first). *)

val remember_protocol_version_if_initialize_succeeded :
  ?otel_transport_context:Otel_dispatch_hook.transport_context ->
  string ->
  request_body:string ->
  response_json:Yojson.Safe.t ->
  unit
(** [remember_protocol_version_if_initialize_succeeded session_id
    ~request_body ~response_json] records initialize protocol/session
    activity only when [response_json] is a successful JSON-RPC response.
    Rejected initialize requests must not start session-duration state. *)

val validate_mcp_session_owner_for_request :
  session_id:string ->
  requester:Server_transport_admission.identity ->
  (unit, string) result
(** [validate_mcp_session_owner_for_request ~session_id ~requester] admits a
    fresh, not-yet-initialized session or a known session owned by [requester].
    A known legacy session without owner metadata and a session owned by a
    different credential both fail closed. *)

val bind_mcp_session_owner_if_initialize_succeeded :
  string ->
  requester:Server_transport_admission.identity ->
  request_body:string ->
  response_json:Yojson.Safe.t ->
  (unit, string) result
(** Atomically binds the credential owner to [session_id] only when the request
    is a successful [initialize]. Repeating the bind for the same owner is
    idempotent; a competing owner is rejected without overwriting the original
    immutable binding. *)

val authorize_mcp_session_delete :
  session_id:string ->
  requester:Server_transport_admission.identity ->
  (unit, string) result
(** Allows DELETE only to the bound credential owner or an explicit [Admin]
    identity. Ownerless legacy sessions therefore require Admin cleanup. *)

val mcp_session_owner :
  string -> Server_transport_admission.identity option
(** Returns the immutable credential owner currently bound to [session_id].
    Exposed for focused persistence and authorization tests. *)

val is_known_session : string -> bool
(** RFC-0100 PR-3 — Q3 default. [true] iff the server has previously
    recorded a protocol version for [session_id] (i.e., an
    [initialize] request has succeeded). The complementary
    {!mcp_profile_by_session} registry is not consulted because it
    is populated on every POST regardless of [initialize]
    completion. *)

val ensure_sse_backing_session_for_known_transport_session :
  transport_session_id:string -> sse_session_id:string -> unit
(** Ensures the legacy SSE session store contains [sse_session_id] only
    when [transport_session_id] is already known to the streamable HTTP
    transport. Unknown client-supplied ids must continue to fail SSE
    registration instead of being minted implicitly. *)

val remember_mcp_profile :
  ?otel_transport_context:Otel_dispatch_hook.transport_context ->
  string -> Server_mcp_transport_http_types.tool_profile -> unit
(** [remember_mcp_profile session_id profile] records the transport
    profile.  For sessions that have completed initialize, it also
    refreshes activity/transport telemetry; uninitialized profile-only
    ids do not start session-duration state. *)

val forget_mcp_session : string -> unit
(** Removes protocol-version, tool-profile, credential-owner, and telemetry
    entries for [session_id]. *)

(** {1 Grace period}

    Sessions whose SSE connection drops are kept for a configurable
    grace period before reaping.  This prevents "Unknown Mcp-Session-Id"
    errors when clients briefly disconnect and reconnect. *)

val grace_period_seconds : float
(** Seconds to keep a session after SSE disconnect.  Default 300 (5 min).
    Configurable via [MASC_SESSION_SSE_GRACE_PERIOD_SEC] env var. *)

(** {1 File persistence}

    Session state (protocol version, profile, credential owner, last-active timestamp)
    is persisted to [\<base_path\>/.masc/mcp_transport_sessions.json].
    On restart, [load_sessions_from_file] restores the state so the
    grace period applies to recently-active sessions. *)

val sessions_file_path : base_path:string -> string
(** Returns the persistence path under the explicitly selected workspace
    [base_path]. Exposed for testing. *)

val save_sessions_to_file : base_path:string -> unit -> unit
(** Serialize current session state and write atomically to disk.
    Called automatically by [reap_stale_sessions] after each cleanup.
    Safe to call at any time — uses write-then-rename. The caller must pass the
    live server workspace base path; persistence never derives it from cwd. *)

val load_sessions_from_file : base_path:string -> unit -> unit
(** Load session state from disk into the in-memory registries.
    Call once during server startup, before the MCP handler accepts
    requests. A missing file is an empty initial state; malformed or unreadable
    state raises so the bootstrap boundary can report the failure explicitly. *)

val profile_label : Server_mcp_transport_http_types.tool_profile -> string
(** Stable label for the MCP HTTP surface a session belongs to.
    Used in profile-mismatch errors and termination logs. *)

val reap_stale_sessions :
  base_path:string -> is_active_session:(string -> bool) -> int
(** [reap_stale_sessions ~base_path ~is_active_session] removes session
    entries whose [session_id] returns [false] from
    [is_active_session].  Returns the number of reaped entries.

    Called periodically by the cleanup loop with
    {!Server_mcp_transport_http_conn.is_active_sse_session} as
    the predicate — this keeps the session-state registry
    bounded against connection churn. *)

(** {1 Profile validation} *)

val validate_mcp_session_profile :
  profile:Server_mcp_transport_http_types.tool_profile ->
  string -> (unit, string) result
(** [validate_mcp_session_profile ~profile session_id] returns
    [Ok ()] when the session is unregistered OR its registered
    profile matches.  [Error] message format:
    [["Session <id> belongs to <existing_label>, not <requested_label>."]]
    Profile labels are pinned via {!profile_label} (private):
    [/mcp] / [/mcp/managed] / [/mcp/operator]. *)

val validate_mcp_session_delete_profile :
  profile:Server_mcp_transport_http_types.tool_profile ->
  string -> (unit, string) result
(** Stricter sibling of {!validate_mcp_session_profile} for
    [DELETE] requests.

    For [Operator_remote] profile: the session MUST be
    registered with [Operator_remote] — unregistered sessions
    return [Error "Session <id> is not registered on /mcp/operator."].
    This is intentional: operator-remote DELETE on an unknown
    session is a permission error, not a no-op.

    For [Full] / [Managed_agent] profiles: same lenient
    semantics as {!validate_mcp_session_profile}. *)

(** {1 Body / header / query parsing} *)

val protocol_version_from_body : string -> string option
(** Alias over {!Mcp_transport_protocol.protocol_version_from_body}.
    Extracts the [params.protocolVersion] from a JSON-RPC
    initialise request body. *)

val get_session_id_query : string -> string option
(** [get_session_id_query target] extracts a [session_id=...]
    or [sessionId=...] query parameter from the URL target.
    Returns [None] when not found.  Both casings are accepted
    as a backward-compat alias. *)

val capitalize_ascii : string -> string
val title_case_header_name : string -> string
(** Internal but exposed because the {!get_header_any_case}
    fallback chain (lower → title-case → upper) depends on
    the title-case transform.  Pure — useful for tests
    asserting the case-insensitive header lookup behaviour. *)

val get_header_any_case :
  Httpun.Headers.t -> string -> string option
(** [get_header_any_case headers name] tries three cases in
    order: original [name], {!title_case_header_name name}
    (e.g. [["Mcp-Session-Id"]]), and uppercase.  Useful when
    the upstream proxy normalises headers inconsistently. *)

val get_cookie_value :
  Httpun.Request.t -> string -> string option
(** [get_cookie_value request cookie_name] parses the [Cookie:]
    header and returns the value for [cookie_name]
    (case-insensitive cookie name match, value trimmed).
    [None] when absent or blank. *)

val get_session_id_any : Httpun.Request.t -> string option
(** Three-tier session-id resolution: query param →
    [Mcp-Session-Id] header → [mcp-session-id] cookie.  The
    fallback order is the operator contract — clients that
    drop one channel still authenticate via the next. *)

(** {1 Protocol version resolution} *)

val get_protocol_version : Httpun.Request.t -> string
(** Returns the [Mcp-Protocol-Version] header or
    {!mcp_protocol_version_default} when absent. *)

val get_protocol_version_header_opt :
  Httpun.Request.t -> string option

val validate_protocol_version_continuity :
  session_id:string -> Httpun.Request.t -> (unit, string) result
(** [validate_protocol_version_continuity ~session_id request]
    enforces:
    - When the session has a remembered version: the request
      header (if present) must match.
    - When the session is unknown: the request header (if
      present) must be valid per {!is_valid_protocol_version}.
    - Missing header is always [Ok ()].

    Error messages pinned:
    - [["Unsupported MCP-Protocol-Version: <v>"]]
    - [["MCP-Protocol-Version mismatch for session <id>: expected <e>, got <g>."]] *)

val get_protocol_version_for_session :
  ?session_id:string -> Httpun.Request.t -> string
(** [get_protocol_version_for_session ?session_id request]
    returns the per-session remembered version when
    [session_id] is provided AND the session has a
    remembered entry; otherwise falls back to the
    request header (or default).  Convenience wrapper for the
    common "I know the session id, give me its version" path. *)

(** {1 Misc helpers} *)

val default_base_path : unit -> string
(** Resolves the launcher-guard-aware default base path.
    The server default starts from the deleted-cwd-safe current working
    directory and routes through
    {!Workspace_utils_backend_setup.resolve_server_default_base_path}.

    This intentionally avoids deriving the base path from [HOME]: a direct
    binary launch from a checkout should keep artifacts under the visible
    launch root unless the operator passes [--base-path] or [MASC_BASE_PATH].
*)

val query_param :
  Httpun.Request.t -> string -> string option
(** [query_param request key] extracts a query parameter from
    the request URL via [Uri.get_query_param].  Pure — no side
    effects. *)
