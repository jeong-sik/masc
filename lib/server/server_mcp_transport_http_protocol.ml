(** Server_mcp_transport_http protocol — version management, headers, session utils.

    Session state (Hashtbl tables + mutex) lives in Server_mcp_transport_http_session.
    This module includes it and adds HTTP-specific utilities. *)

module Http = Http_server_eio
module Http_negotiation = Mcp_transport_protocol.Http_negotiation

(* Session management: single source of truth with Eio.Mutex protection.
   Brings in Mcp_eio alias, Hashtbl tables, mutex, and all session functions. *)
include Server_mcp_transport_http_session

type auth_failure = Server_mcp_transport_http_types.auth_failure =
  { message : string
  ; auth_error_code : string option
  }

let auth_failure_data failure =
  Option.map
    (fun code -> `Assoc [ "auth_error_code", `String code ])
    failure.auth_error_code
;;

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

let is_http_error_response = Server_mcp_transport_http_headers.is_http_error_response

let request_runtime_result = Server_mcp_transport_http_headers.request_runtime_result

let request_force_json_response =
  Server_mcp_transport_http_headers.request_force_json_response

let classify_mcp_accept = Server_mcp_transport_http_headers.classify_mcp_accept

let validate_2026_request_headers =
  Server_mcp_transport_http_headers.validate_2026_request_headers

let should_use_sse_for_body =
  Server_mcp_transport_http_headers.should_use_sse_for_body

let force_json_response = Server_mcp_transport_http_headers.force_json_response
