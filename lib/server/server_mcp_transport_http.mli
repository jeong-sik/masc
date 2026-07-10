type tool_profile = Server_mcp_transport_http_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote

type runtime = Server_mcp_transport_http_types.runtime = {
  base_path : string;
  sw : Eio.Switch.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  handle_request :
    ?profile:tool_profile ->
    ?mcp_session_id:string ->
    ?otel_mcp_protocol_version:string ->
    ?otel_transport_context:Otel_dispatch_hook.transport_context ->
    ?auth_token:string ->
    ?internal_keeper_runtime:bool ->
    string ->
    Yojson.Safe.t;
  clear_resource_subscriptions_for_session : string -> unit;
}

type deps = {
  get_origin : Httpun.Request.t -> string;
  cors_headers : string -> (string * string) list;
  auth_token_from_request : Httpun.Request.t -> string option;
  is_ready : unit -> bool;
  get_runtime_result : unit -> (runtime, string) result;
  get_base_path : unit -> string;
}

val mcp_protocol_versions : string list
val mcp_protocol_version_default : string
val default_base_path : unit -> string
val is_valid_protocol_version : string -> bool
val remember_protocol_version :
  ?otel_transport_context:Otel_dispatch_hook.transport_context ->
  string ->
  string ->
  unit

val remember_protocol_version_if_initialize_succeeded :
  ?otel_transport_context:Otel_dispatch_hook.transport_context ->
  string ->
  request_body:string ->
  response_json:Yojson.Safe.t ->
  unit

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

val authorize_mcp_session_delete :
  session_id:string ->
  requester:Server_transport_admission.identity ->
  (unit, string) result

val mcp_session_owner :
  string -> Server_transport_admission.identity option

val authorize_mcp_profile_admission :
  base_path:string ->
  profile:tool_profile ->
  Httpun.Request.t ->
  (Server_transport_admission.admission, Masc_domain.masc_error) result
(** Strict per-credential admission shared by the H1 and H2 MCP session
    surfaces. [Full] and [Managed_agent] require [CanReadState];
    [Operator_remote] requires [CanAdmin]. *)

type mcp_sse_owner_lease
(** An opaque, connection-scoped ownership claim for an SSE wire session id.
    Lease identity is immutable; a reconnect by the same credential replaces
    the prior lease without allowing its stale disconnect callback to release
    the replacement.  Initialized Agent streams still derive authority from
    the persistent transport-session owner, not from this lease. *)

val validate_mcp_sse_session_owner_for_request :
  session_id:string ->
  sse_kind:Sse.session_kind ->
  requester:Server_transport_admission.identity ->
  (unit, string) result
(** [validate_mcp_sse_session_owner_for_request] requires Agent streams to use
    an initialized, credential-owned MCP session.  Observer and Presence
    streams may use a fresh wire id, but an existing ephemeral lease must have
    the same credential owner.  Known ownerless sessions fail closed. *)

val claim_mcp_sse_session_owner_for_request :
  session_id:string ->
  sse_kind:Sse.session_kind ->
  requester:Server_transport_admission.identity ->
  (mcp_sse_owner_lease, string) result
(** Atomically claims the SSE wire id after validation.  Initialized sessions
    remain governed by the transport-session owner SSOT; their supplemental
    connection lease only preserves that owner boundary if the inactive
    protocol state is reaped while the stream is being connected or remains
    open. *)

val activate_mcp_sse_owner_lease :
  mcp_sse_owner_lease -> (unit, string) result
(** Promotes a connection claim after [Sse.register] succeeds.  Until this
    transition, another same-owner reconnect is rejected explicitly, so two
    concurrent setup paths cannot stop or overwrite one another. *)

val release_mcp_sse_owner_lease : mcp_sse_owner_lease -> unit
(** Releases [lease] only when it is still current.  A failed reconnect setup
    restores the prior active lease until the old connection is stopped;
    therefore a stale disconnect callback cannot release a newer reconnect,
    and a pre-stop setup failure cannot orphan the existing connection owner.
    Releasing the current owner of a non-transport stream also removes its
    credential-bound backing session before a different owner may claim the
    wire id. *)

val remember_mcp_profile :
  ?otel_transport_context:Otel_dispatch_hook.transport_context ->
  string ->
  tool_profile ->
  unit
val forget_mcp_session : string -> unit
val profile_label : tool_profile -> string
val reap_stale_sessions :
  base_path:string -> is_active_session:(string -> bool) -> int
val validate_mcp_session_profile :
  profile:tool_profile -> string -> (unit, string) result
val validate_mcp_session_delete_profile :
  profile:tool_profile -> string -> (unit, string) result
val method_from_body : string -> string option
val inject_agent_name_into_body :
  ?rewrite_existing:bool ->
  ?strip_token:bool ->
  agent_name:string ->
  string ->
  string
val body_with_canonical_http_actor :
  base_path:string ->
  auth_token:string option ->
  Httpun.Request.t ->
  string ->
  string
val validate_session_requirement :
  session_was_provided:bool -> string -> (unit, string) result
val validate_session_known :
  session_was_provided:bool ->
  is_known:bool ->
  string ->
  (unit, string) result
val is_known_session : string -> bool
val ensure_sse_backing_session_for_known_transport_session :
  transport_session_id:string -> sse_session_id:string -> unit

val body_tools_call_name : string -> string option
val body_jsonrpc_id : string -> Yojson.Safe.t option
val protocol_version_from_body : string -> string option
val get_session_id_query : string -> string option
val get_header_any_case : Httpun.Headers.t -> string -> string option
val get_cookie_value : Httpun.Request.t -> string -> string option
val get_session_id_any : Httpun.Request.t -> string option
val get_protocol_version : Httpun.Request.t -> string
val validate_protocol_version_continuity :
  session_id:string -> Httpun.Request.t -> (unit, string) result
val get_protocol_version_for_session :
  ?session_id:string -> Httpun.Request.t -> string
val request_force_json_response : Httpun.Request.t -> bool
val classify_mcp_accept :
  Httpun.Request.t -> Mcp_transport_protocol.Http_negotiation.accept_mode
val request_uses_stateless_protocol : Httpun.Request.t -> string -> bool
val validate_2026_request_headers :
  Httpun.Request.t -> string -> (unit, string) result
val should_use_sse_for_body :
  Httpun.Request.t ->
  string ->
  Mcp_transport_protocol.Http_negotiation.accept_mode ->
  bool
val force_json_response : bool
val get_last_event_id : Httpun.Request.t -> int option
val mcp_headers : string -> string -> (string * string) list
val json_headers :
  deps:deps -> string -> string -> string -> (string * string) list
val check_sse_connect_guard
  : string -> (unit, Sse_reject_reason.t * float) result
val stop_sse_session : string -> unit
val is_active_sse_session : string -> bool
val reap_stale_guards : unit -> int
val close_all_sse_connections : unit -> unit
val handle_post_mcp :
  deps:deps ->
  ?profile:tool_profile ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  unit
val handle_get_mcp :
  deps:deps ->
  ?profile:tool_profile ->
  ?sse_kind:Sse.session_kind ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  unit
val handle_get_operator_mcp :
  deps:deps -> Httpun.Request.t -> Httpun.Reqd.t -> unit
val handle_delete_mcp :
  deps:deps ->
  ?profile:tool_profile ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  unit
val handle_ag_ui_events :
  deps:deps -> Httpun.Request.t -> Httpun.Reqd.t -> unit
val handle_presence_events :
  deps:deps -> Httpun.Request.t -> Httpun.Reqd.t -> unit
