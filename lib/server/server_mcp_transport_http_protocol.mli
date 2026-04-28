(** Server_mcp_transport_http_protocol — protocol-level utilities
    on top of the session-state module.

    Layered:
    - {!Server_mcp_transport_http_session} (state: session
      registries, mutex, protocol-version cache).
    - {b This module}: re-exports the session surface via
      [include] and adds:

      + JSON body method extractor ({!method_from_body}).
      + Session-requirement gate ({!validate_session_requirement}).
      + Re-exports of header / accept / runtime-resolution helpers
        from {!Server_mcp_transport_http_headers}.
      + The {!deps} dependency record (transparent alias to
        {!Server_mcp_transport_http_types.deps}).

    Module aliases [Http] / [Http_negotiation] are exposed because
    sibling consumers (e.g. {!Server_h2_gateway},
    {!Server_mcp_transport_http}) reach them via the [include]
    cascade. *)

include module type of struct
  include Server_mcp_transport_http_session
end

(** {1 Module aliases (cascade-visible)} *)

module Http = Http_server_eio
module Http_negotiation = Mcp_transport_protocol.Http_negotiation

(** {1 Capability injection record} *)

type deps = Server_mcp_transport_http_types.deps = {
  get_origin : Httpun.Request.t -> string;
  cors_headers : string -> (string * string) list;
  auth_token_from_request : Httpun.Request.t -> string option;
  is_ready : unit -> bool;
  get_runtime_result :
    unit -> (Server_mcp_transport_http_types.runtime, string) result;
  get_base_path : unit -> string;
  verify_mcp_auth :
    base_path:string -> Httpun.Request.t -> (unit, string) result;
  verify_mcp_observer_stream_auth :
    base_path:string -> Httpun.Request.t -> (unit, string) result;
  verify_operator_mcp_auth :
    base_path:string -> Httpun.Request.t -> (unit, string) result;
}
(** Transparent alias of {!Server_mcp_transport_http_types.deps}.
    Re-declared here so cascade consumers see the record fields
    without needing to reach into [Types]. *)

(** {1 Body parsing} *)

val method_from_body : string -> string option
(** [method_from_body body_str] extracts the JSON-RPC [method] field
    from a request body.  Returns [None] when:

    - The body is not valid JSON ([Yojson.Json_error] is caught).
    - The root is not [\`Assoc].
    - The [method] field is missing or not [\`String _].

    Used by {!validate_session_requirement} to decide whether a
    session-id-less call is permitted. *)

val validate_session_requirement :
  session_was_provided:bool -> string -> (unit, string) result
(** [validate_session_requirement ~session_was_provided body_str]
    enforces the MCP session-id contract:

    - Returns [Ok ()] when [session_was_provided = true] (session
      header / cookie / query-param resolved).
    - When [session_was_provided = false], inspects the JSON-RPC
      method via {!method_from_body}.  Permits the bootstrap
      methods [initialize] / [notifications/initialized] / [ping]
      to proceed without a session id; everything else rejects:

      [Error "Mcp-Session-Id header required. Call initialize first
      to obtain a session."] *)

(** {1 Re-exports} *)

val protocol_version_from_body : string -> string option
(** Re-export of
    {!Mcp_transport_protocol.protocol_version_from_body}. *)

val is_http_error_response : Yojson.Safe.t -> bool
(** Re-export of
    {!Server_mcp_transport_http_headers.is_http_error_response}. *)

val request_runtime_result :
  deps -> (Server_mcp_transport_http_types.runtime, string) result
(** Re-export of
    {!Server_mcp_transport_http_headers.request_runtime_result}.
    Calls [deps.get_runtime_result ()] without inspecting the
    request — the request is not needed for runtime resolution. *)

val request_force_json_response : Httpun.Request.t -> bool
(** Re-export of
    {!Server_mcp_transport_http_headers.request_force_json_response}. *)

val allow_legacy_accept : bool
(** Re-export of
    {!Server_mcp_transport_http_headers.allow_legacy_accept}.
    Captured at module init from [MASC_ALLOW_LEGACY_ACCEPT]. *)

val classify_mcp_accept :
  Httpun.Request.t -> Mcp_transport_protocol.Http_negotiation.accept_mode
(** Re-export of
    {!Server_mcp_transport_http_headers.classify_mcp_accept}. *)

val classify_mcp_accept_for_body :
  Httpun.Request.t ->
  string ->
  Mcp_transport_protocol.Http_negotiation.accept_mode
(** Re-export of
    {!Server_mcp_transport_http_headers.classify_mcp_accept_for_body}. *)

val should_use_sse_for_body :
  Httpun.Request.t ->
  string ->
  Mcp_transport_protocol.Http_negotiation.accept_mode ->
  bool
(** Re-export of
    {!Server_mcp_transport_http_headers.should_use_sse_for_body}. *)

val legacy_accept_warning_headers :
  Mcp_transport_protocol.Http_negotiation.accept_mode ->
  (string * string) list
(** Re-export of
    {!Server_mcp_transport_http_headers.legacy_accept_warning_headers}.
    Returns warn-deprecation headers when the accept mode is
    [Legacy_accepted], else [\[\]]. *)

val legacy_transport_deprecation_headers : (string * string) list
(** Re-export of
    {!Server_mcp_transport_http_headers.legacy_transport_deprecation_headers}. *)

val force_json_response : bool
(** Re-export of
    {!Server_mcp_transport_http_headers.force_json_response}.
    [true] iff [MASC_FORCE_JSON_RESPONSE] or [MCP_FORCE_JSON_RESPONSE]
    is set at module init. *)
