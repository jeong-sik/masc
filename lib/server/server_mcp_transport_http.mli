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
}

type auth_failure = Server_mcp_transport_http_types.auth_failure =
  { message : string
  ; auth_error_code : string option
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

val mcp_protocol_versions : string list
val mcp_protocol_version_default : string
val default_base_path : unit -> string
val is_valid_protocol_version : string -> bool
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
val body_tools_call_name : string -> string option
val observer_session_id : Httpun.Request.t -> string option
val request_force_json_response : Httpun.Request.t -> bool
val classify_mcp_accept :
  Httpun.Request.t -> Mcp_transport_protocol.Http_negotiation.accept_mode
val validate_2026_request_headers :
  Httpun.Request.t -> string -> (unit, string) result
val should_use_sse_for_body :
  Httpun.Request.t ->
  Mcp_transport_protocol.Http_negotiation.accept_mode ->
  bool
val force_json_response : bool
val mcp_headers : string -> (string * string) list
val json_headers :
  deps:deps -> string -> string -> (string * string) list
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
val handle_get_events :
  deps:deps -> Httpun.Request.t -> Httpun.Reqd.t -> unit
val handle_ag_ui_events :
  deps:deps -> Httpun.Request.t -> Httpun.Reqd.t -> unit
val handle_presence_events :
  deps:deps -> Httpun.Request.t -> Httpun.Reqd.t -> unit
