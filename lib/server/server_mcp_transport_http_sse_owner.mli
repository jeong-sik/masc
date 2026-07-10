(** Credential ownership for long-lived MCP-adjacent SSE wire ids.

    Initialized MCP Agent streams remain governed by the transport-session
    owner in {!Server_mcp_transport_http_session}.  Dashboard Observer,
    Presence, and AG-UI streams may start from a client-generated id, so this
    module adds a process-local connection lease without persisting phantom MCP
    protocol sessions. *)

type lease

val validate_mcp_session_owner_for_request :
  session_id:string ->
  requester:Server_transport_admission.identity ->
  (unit, string) result

val bind_mcp_session_owner_if_initialize_succeeded :
  string ->
  requester:Server_transport_admission.identity ->
  request_body:string ->
  response_json:Yojson.Safe.t ->
  (unit, string) result

val validate_mcp_sse_session_owner_for_request :
  session_id:string ->
  sse_kind:Sse.session_kind ->
  requester:Server_transport_admission.identity ->
  (unit, string) result

val claim_mcp_sse_session_owner_for_request :
  session_id:string ->
  sse_kind:Sse.session_kind ->
  requester:Server_transport_admission.identity ->
  (lease, string) result

val activate : lease -> (unit, string) result
val discard_previous : lease -> unit
val release : lease -> unit

val ensure_backing_session_for_owner :
  session_id:string ->
  requester:Server_transport_admission.identity ->
  (unit, string) result

val forget_mcp_session : string -> unit
(** Invalidates any in-flight/active SSE lease under the same transition lock
    before forgetting the initialized transport session.  DELETE callers must
    invoke this before stopping the connection, so an in-flight Agent GET
    cannot publish after deletion. *)
