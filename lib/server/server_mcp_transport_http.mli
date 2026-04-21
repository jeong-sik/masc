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
    ?auth_token:string ->
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
  verify_mcp_auth : base_path:string -> Httpun.Request.t -> (unit, string) result;
  verify_mcp_observer_stream_auth :
    base_path:string -> Httpun.Request.t -> (unit, string) result;
  verify_operator_mcp_auth :
    base_path:string -> Httpun.Request.t -> (unit, string) result;
}

val mcp_protocol_versions : string list
val mcp_protocol_version_default : string
val default_base_path : unit -> string
val is_valid_protocol_version : string -> bool
val remember_protocol_version : string -> string -> unit
val remember_mcp_profile : string -> tool_profile -> unit
val forget_mcp_session : string -> unit
val reap_stale_sessions : is_active_session:(string -> bool) -> int
val validate_mcp_session_profile :
  profile:tool_profile -> string -> (unit, string) result
val validate_mcp_session_delete_profile :
  profile:tool_profile -> string -> (unit, string) result
val method_from_body : string -> string option
val validate_session_requirement :
  session_was_provided:bool -> string -> (unit, string) result
val protocol_version_from_body : string -> string option
val get_session_id_query : string -> string option
val get_header_any_case : Httpun.Headers.t -> string -> string option
val get_cookie_value : Httpun.Request.t -> string -> string option
val get_session_id_any : Httpun.Request.t -> string option
val legacy_messages_endpoint_url : Httpun.Request.t -> string -> string
val get_protocol_version : Httpun.Request.t -> string
val validate_protocol_version_continuity :
  session_id:string -> Httpun.Request.t -> (unit, string) result
val get_protocol_version_for_session :
  ?session_id:string -> Httpun.Request.t -> string
val request_force_json_response : Httpun.Request.t -> bool
val allow_legacy_accept : bool
val classify_mcp_accept :
  Httpun.Request.t -> Mcp_transport_protocol.Http_negotiation.accept_mode
val classify_mcp_accept_for_body :
  Httpun.Request.t -> string -> Mcp_transport_protocol.Http_negotiation.accept_mode
val should_use_sse_for_body :
  Httpun.Request.t ->
  string ->
  Mcp_transport_protocol.Http_negotiation.accept_mode ->
  bool
val legacy_accept_warning_headers :
  Mcp_transport_protocol.Http_negotiation.accept_mode -> (string * string) list
val legacy_transport_deprecation_headers : (string * string) list
val force_json_response : bool
val get_last_event_id : Httpun.Request.t -> int option
val mcp_headers : string -> string -> (string * string) list
val json_headers :
  deps:deps -> string -> string -> string -> (string * string) list
val check_sse_connect_guard : string -> (unit, string * float) result
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
  ?legacy_messages_endpoint:(string -> string) ->
  ?profile:tool_profile ->
  ?sse_kind:Sse.session_kind ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  unit
val sse_simple_handler : deps:deps -> Httpun.Request.t -> Httpun.Reqd.t -> unit
val handle_get_operator_mcp :
  deps:deps -> Httpun.Request.t -> Httpun.Reqd.t -> unit
val handle_post_messages :
  deps:deps -> Httpun.Request.t -> Httpun.Reqd.t -> unit
val handle_delete_mcp :
  deps:deps ->
  ?profile:tool_profile ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  unit
val handle_ag_ui_events :
  deps:deps -> Httpun.Request.t -> Httpun.Reqd.t -> unit
