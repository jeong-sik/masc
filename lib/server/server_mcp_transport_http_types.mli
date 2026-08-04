type tool_profile =
  | Full
  | Managed_agent
  | Operator_remote

type auth_failure =
  { message : string
  ; auth_error_code : string option
  }

val auth_failure_of_masc_error : Masc_domain.masc_error -> auth_failure
(** Encodes one typed authentication failure for the MCP transport. This is
    the shared HTTP/1.1 and HTTP/2 boundary; callers must not rebuild the wire
    code independently. *)

type runtime = {
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
  verify_mcp_auth :
    base_path:string -> Httpun.Request.t -> (unit, auth_failure) result;
  verify_mcp_observer_stream_auth :
    base_path:string -> Httpun.Request.t -> (unit, auth_failure) result;
  verify_operator_mcp_auth :
    base_path:string -> Httpun.Request.t -> (unit, auth_failure) result;
}
