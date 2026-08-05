(** Server_mcp_transport_http_protocol — protocol-level utilities
    on top of the observer-stream state module.

    Layered:
    - {!Server_mcp_transport_http_session} (observer stream state).
    - {b This module}: re-exports the session surface via
      [include] and adds:

      + Re-exports of header / accept / runtime-resolution helpers
        from {!Server_mcp_transport_http_headers}.
      + The {!deps} dependency record (transparent alias to
        {!Server_mcp_transport_http_types.deps}).

    Module aliases [Http] / [Http_negotiation] are exposed because
    sibling consumers (e.g. {!Server_h2_gateway},
    {!Server_mcp_transport_http}) reach them via the [include]
    runtime. *)

include module type of struct
  include Server_mcp_transport_http_session
end

(** {1 Module aliases (runtime-visible)} *)

module Http = Http_server_eio
module Http_negotiation = Mcp_transport_protocol.Http_negotiation

type auth_failure = Server_mcp_transport_http_types.auth_failure =
  { message : string
  ; auth_error_code : string option
  }

val auth_failure_data : auth_failure -> Yojson.Safe.t option
(** JSON-RPC error data for a typed authentication failure. *)

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
    base_path:string -> Httpun.Request.t -> (unit, auth_failure) result;
  verify_mcp_observer_stream_auth :
    base_path:string -> Httpun.Request.t -> (unit, auth_failure) result;
  verify_operator_mcp_auth :
    base_path:string -> Httpun.Request.t -> (unit, auth_failure) result;
}
(** Transparent alias of {!Server_mcp_transport_http_types.deps}.
    Re-declared here so runtime consumers see the record fields
    without needing to reach into [Types]. *)

(** {1 Re-exports} *)

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

val classify_mcp_accept :
  Httpun.Request.t -> Mcp_transport_protocol.Http_negotiation.accept_mode
(** Re-export of
    {!Server_mcp_transport_http_headers.classify_mcp_accept}. *)

val validate_2026_request_headers :
  Httpun.Request.t -> string -> (unit, string) result
(** Re-export of
    {!Server_mcp_transport_http_headers.validate_2026_request_headers}. *)

val should_use_sse_for_body :
  Httpun.Request.t ->
  Mcp_transport_protocol.Http_negotiation.accept_mode ->
  bool
(** Re-export of
    {!Server_mcp_transport_http_headers.should_use_sse_for_body}. *)

val force_json_response : bool
(** Re-export of
    {!Server_mcp_transport_http_headers.force_json_response}.
    [true] iff [MASC_FORCE_JSON_RESPONSE]
    is set at module init. *)
