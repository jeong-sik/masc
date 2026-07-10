(** MCP Streamable HTTP session facade plus request parsing helpers.

    Durable session state belongs exclusively to
    {!Server_mcp_transport_session_store}.  Every stateful operation therefore
    requires an explicit BasePath-scoped store handle; this module owns no
    process-global registry or persistence lifecycle. *)

module Store = Server_mcp_transport_session_store

(** {1 Protocol versioning} *)

val mcp_protocol_versions : string list
(** Alias over {!Mcp_transport_protocol.supported_protocol_versions}. *)

val mcp_protocol_version_default : string
(** Alias over {!Mcp_transport_protocol.default_protocol_version}. *)

val is_valid_protocol_version : string -> bool

(** {1 Store-backed session state} *)

val is_known_session : sessions:Store.t -> string -> bool
(** [true] exactly when the supplied id is active in [sessions].  Unknown ids
    and retained deletion tombstones are not active sessions. *)

val mcp_session_owner :
  sessions:Store.t -> string -> Server_transport_admission.identity option
(** Returns the immutable owner of an active session. *)

val validate_mcp_session_owner_for_request :
  sessions:Store.t ->
  session_id:string ->
  requester:Server_transport_admission.identity ->
  (unit, string) result
(** Admits an unknown, not-yet-initialized id or an active session owned by
    [requester].  A different owner fails closed.  Callers separately enforce
    that client-supplied ids are known. *)

val authorize_mcp_session_delete :
  sessions:Store.t ->
  session_id:string ->
  requester:Server_transport_admission.identity ->
  (unit, string) result
(** Allows DELETE to the active session owner or an explicit [Admin].  Unknown
    or deleted sessions require Admin authorization before the store returns
    their typed lifecycle result. *)

val ensure_sse_backing_session_for_known_transport_session :
  sessions:Store.t -> transport_session_id:string -> sse_session_id:string -> unit
(** Ensures the legacy SSE backing store contains [sse_session_id] only when
    [transport_session_id] is active in [sessions]. *)

type initialize_commit_result =
  | Not_initialize
  | Initialized
(** The classification and durable outcome of
    {!commit_successful_initialize}. *)

val commit_successful_initialize :
  sessions:Store.t ->
  session_id:string ->
  profile:Server_mcp_transport_http_types.tool_profile ->
  requester:Server_transport_admission.identity ->
  otel_transport_context:Otel_dispatch_hook.transport_context option ->
  request_body:string ->
  response_json:Yojson.Safe.t ->
  (initialize_commit_result, Store.mutation_error) result
(** Commits exactly one complete {!Store.session} when [request_body] is a
    JSON-RPC 2.0 [initialize] request with an id and an explicit supported
    [params.protocolVersion], and [response_json] is the matching successful
    JSON-RPC response.

    Non-initialize, malformed, unsupported, failed, or mismatched exchanges
    return [Ok Not_initialize] without mutating [sessions].  A qualifying
    exchange delegates one atomic durable transition to {!Store.initialize};
    its typed mutation failure is returned unchanged. *)

val profile_label : Server_mcp_transport_http_types.tool_profile -> string
(** Stable label for the MCP HTTP surface a session belongs to. *)

val validate_mcp_session_profile :
  sessions:Store.t ->
  profile:Server_mcp_transport_http_types.tool_profile ->
  string ->
  (unit, string) result
(** Accepts an unknown/deleted session or an active session whose stored
    profile equals [profile]. *)

val validate_mcp_session_delete_profile :
  sessions:Store.t ->
  profile:Server_mcp_transport_http_types.tool_profile ->
  string ->
  (unit, string) result
(** For [Operator_remote], DELETE requires an active operator session.  The
    other profiles use {!validate_mcp_session_profile}. *)

(** {1 Body / header / query parsing} *)

val protocol_version_from_body : string -> string option
(** Alias over {!Mcp_transport_protocol.protocol_version_from_body}. *)

val get_session_id_query : string -> string option
(** Extracts [session_id] or the legacy [sessionId] alias from a request
    target. *)

val capitalize_ascii : string -> string
val title_case_header_name : string -> string

val get_header_any_case : Httpun.Headers.t -> string -> string option
(** Looks up the original, title-case, then uppercase header spelling. *)

val get_cookie_value : Httpun.Request.t -> string -> string option
(** Returns a non-empty cookie value, matching the cookie name
    case-insensitively. *)

val get_session_id_any : Httpun.Request.t -> string option
(** Resolves query parameter, header, then cookie in that order. *)

(** {1 Protocol version resolution} *)

val get_protocol_version : Httpun.Request.t -> string
val get_protocol_version_header_opt : Httpun.Request.t -> string option

val validate_protocol_version_continuity :
  sessions:Store.t ->
  session_id:string ->
  Httpun.Request.t ->
  (unit, string) result
(** For an active session, a supplied protocol header must be supported and
    equal its initialized version.  For an unknown/deleted id, a supplied
    header need only be supported.  A missing header is accepted. *)

val get_protocol_version_for_session :
  sessions:Store.t -> ?session_id:string -> Httpun.Request.t -> string
(** Returns the active session's initialized version when available, otherwise
    the request header or protocol default. *)

val query_param : Httpun.Request.t -> string -> string option
(** Extracts a query parameter via {!Uri.get_query_param}. *)
