type deps = {
  get_origin : Httpun.Request.t -> string;
  cors_headers : string -> (string * string) list;
  auth_token_from_request : Httpun.Request.t -> string option;
  get_server_state_opt : unit -> Mcp_server.server_state option;
  get_sw : unit -> Eio.Switch.t option;
  get_clock : unit -> float Eio.Time.clock_ty Eio.Resource.t option;
  verify_mcp_auth : base_path:string -> Httpun.Request.t -> (unit, string) result;
  verify_operator_mcp_auth :
    base_path:string -> Httpun.Request.t -> (unit, string) result;
}

let to_types_deps (deps : deps) : Server_mcp_transport_http_types.deps =
  {
    get_origin = deps.get_origin;
    cors_headers = deps.cors_headers;
    auth_token_from_request = deps.auth_token_from_request;
    get_server_state_opt = deps.get_server_state_opt;
    get_sw = deps.get_sw;
    get_clock = deps.get_clock;
    verify_mcp_auth = deps.verify_mcp_auth;
    verify_operator_mcp_auth = deps.verify_operator_mcp_auth;
  }

let mcp_protocol_versions =
  Server_mcp_transport_http_session.mcp_protocol_versions

let mcp_protocol_version_default =
  Server_mcp_transport_http_session.mcp_protocol_version_default

let default_base_path = Server_mcp_transport_http_session.default_base_path
let is_valid_protocol_version =
  Server_mcp_transport_http_session.is_valid_protocol_version

let remember_protocol_version =
  Server_mcp_transport_http_session.remember_protocol_version

let remember_mcp_profile =
  Server_mcp_transport_http_session.remember_mcp_profile

let forget_mcp_session = Server_mcp_transport_http_session.forget_mcp_session

let validate_mcp_session_profile =
  Server_mcp_transport_http_session.validate_mcp_session_profile

let validate_mcp_session_delete_profile =
  Server_mcp_transport_http_session.validate_mcp_session_delete_profile

let protocol_version_from_body =
  Server_mcp_transport_http_session.protocol_version_from_body

let get_session_id_query = Server_mcp_transport_http_session.get_session_id_query
let get_header_any_case = Server_mcp_transport_http_session.get_header_any_case
let get_cookie_value = Server_mcp_transport_http_session.get_cookie_value
let get_session_id_any = Server_mcp_transport_http_session.get_session_id_any

let legacy_messages_endpoint_url =
  Server_mcp_transport_http_session.legacy_messages_endpoint_url

let get_protocol_version = Server_mcp_transport_http_session.get_protocol_version

let validate_protocol_version_continuity =
  Server_mcp_transport_http_session.validate_protocol_version_continuity

let get_protocol_version_for_session =
  Server_mcp_transport_http_session.get_protocol_version_for_session

let request_force_json_response =
  Server_mcp_transport_http_headers.request_force_json_response

let allow_legacy_accept = Server_mcp_transport_http_headers.allow_legacy_accept
let classify_mcp_accept = Server_mcp_transport_http_headers.classify_mcp_accept

let legacy_accept_warning_headers =
  Server_mcp_transport_http_headers.legacy_accept_warning_headers

let legacy_transport_deprecation_headers =
  Server_mcp_transport_http_headers.legacy_transport_deprecation_headers

let force_json_response = Server_mcp_transport_http_headers.force_json_response
let get_last_event_id = Server_mcp_transport_http_headers.get_last_event_id
let mcp_headers = Server_mcp_transport_http_headers.mcp_headers

let json_headers ~deps session_id protocol_version origin =
  Server_mcp_transport_http_headers.json_headers ~deps:(to_types_deps deps)
    session_id protocol_version origin

let check_sse_connect_guard =
  Server_mcp_transport_http_sse.check_sse_connect_guard

let stop_sse_session = Server_mcp_transport_http_sse.stop_sse_session

let close_all_sse_connections =
  Server_mcp_transport_http_sse.close_all_sse_connections

let handle_post_mcp ~deps ?profile request reqd =
  Server_mcp_transport_http_mcp_handlers.handle_post_mcp
    ~deps:(to_types_deps deps) ?profile request reqd

let handle_get_mcp ~deps ?legacy_messages_endpoint ?profile request reqd =
  Server_mcp_transport_http_mcp_handlers.handle_get_mcp
    ~deps:(to_types_deps deps) ?legacy_messages_endpoint ?profile request reqd

let sse_simple_handler ~deps request reqd =
  Server_mcp_transport_http_ag_ui.sse_simple_handler
    ~deps:(to_types_deps deps) request reqd

let handle_get_operator_mcp ~deps request reqd =
  Server_mcp_transport_http_admin.handle_get_operator_mcp
    ~deps:(to_types_deps deps) request reqd

let handle_post_messages ~deps request reqd =
  Server_mcp_transport_http_admin.handle_post_messages
    ~deps:(to_types_deps deps) request reqd

let handle_delete_mcp ~deps ?profile request reqd =
  Server_mcp_transport_http_admin.handle_delete_mcp
    ~deps:(to_types_deps deps) ?profile request reqd

let handle_ag_ui_events ~deps request reqd =
  Server_mcp_transport_http_ag_ui.handle_ag_ui_events
    ~deps:(to_types_deps deps) request reqd
