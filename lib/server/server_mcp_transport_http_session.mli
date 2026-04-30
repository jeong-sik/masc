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

    Two atomic [SMap.t] registries keyed by session id store
    per-session protocol version and tool profile.  All
    accessors below are thread-safe via internal CAS loops. *)

val remember_protocol_version : string -> string -> unit
(** [remember_protocol_version session_id version] records the
    version when [is_valid_protocol_version version] is [true];
    silently no-ops on unknown versions (the upstream caller is
    expected to have validated first). *)

val remember_mcp_profile :
  string -> Server_mcp_transport_http_types.tool_profile -> unit

val forget_mcp_session : string -> unit
(** Removes both the protocol-version and tool-profile entries
    for [session_id]. *)

val profile_label : Server_mcp_transport_http_types.tool_profile -> string
(** Stable label for the MCP HTTP surface a session belongs to.
    Used in profile-mismatch errors and termination logs. *)

val reap_stale_sessions :
  is_active_session:(string -> bool) -> int
(** [reap_stale_sessions ~is_active_session] removes session
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

val legacy_messages_endpoint_url :
  Httpun.Request.t -> string -> string
(** [legacy_messages_endpoint_url request session_id] returns
    the absolute URL for the legacy [/messages?session_id=...]
    endpoint.

    Protocol resolution:
    - [X-Forwarded-Proto] header value when present.
    - Otherwise [https] when [Host:] starts with the literal
      prefix [["masc.crying.pict"]] (the Cloudflare tunnel
      hostname); else [http].

    The 16-char tunnel-host prefix is pinned at the contract
    seam: an earlier version used a length-mismatched
    [String.sub] (17-char substring vs 16-char literal) which
    was always false, so tunnel hosts silently advertised
    [http://].  Pinning prevents drift. *)

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
    When the [MASC_BASE_PATH] env var is set, returns
    [Sys.getcwd ()] (operator opted into project-local
    artifacts).  Otherwise prefers [HOME] (then [Sys.getcwd ()]
    fallback) and routes through
    {!Coord_utils_backend_setup.resolve_server_default_base_path}.

    The HOME-preference is intentional: a direct binary launch
    from a checkout with its own [.masc] must NOT silently
    inherit a stale parent [MASC_BASE_PATH].  Pinning at the
    contract seam. *)

val query_param :
  Httpun.Request.t -> string -> string option
(** [query_param request key] extracts a query parameter from
    the request URL via [Uri.get_query_param].  Pure — no side
    effects. *)
