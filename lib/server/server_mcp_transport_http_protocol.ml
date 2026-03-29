(** Server_mcp_transport_http protocol — version management, headers, session utils.

    Session state (Hashtbl tables + mutex) lives in Server_mcp_transport_http_session.
    This module includes it and adds HTTP-specific utilities. *)

module Http = Http_server_eio
module Http_negotiation = Mcp_transport_protocol.Http_negotiation

(* Session management: single source of truth with Eio.Mutex protection.
   Brings in Mcp_eio alias, Hashtbl tables, mutex, and all session functions. *)
include Server_mcp_transport_http_session

type deps = Server_mcp_transport_http_types.deps = {
  get_origin : Httpun.Request.t -> string;
  cors_headers : string -> (string * string) list;
  auth_token_from_request : Httpun.Request.t -> string option;
  get_server_state_opt : unit -> Mcp_server.server_state option;
  get_base_path : unit -> string;
  get_sw : unit -> Eio.Switch.t option;
  get_clock : unit -> float Eio.Time.clock_ty Eio.Resource.t option;
  verify_mcp_auth : base_path:string -> Httpun.Request.t -> (unit, string) result;
  verify_operator_mcp_auth :
    base_path:string -> Httpun.Request.t -> (unit, string) result;
}

let method_from_body body_str =
  try
    let json = Yojson.Safe.from_string body_str in
    match json with
    | `Assoc fields -> (
        match List.assoc_opt "method" fields with
        | Some (`String m) -> Some m
        | _ -> None)
    | _ -> None
  with Yojson.Json_error _ -> None

let validate_session_requirement ~session_was_provided body_str =
  if session_was_provided then Ok ()
  else
    match method_from_body body_str with
    | Some "initialize" | Some "notifications/initialized" | Some "ping" ->
        Ok ()
    | Some _ | None ->
        Error
          "Mcp-Session-Id header required. Call initialize first to obtain a \
           session."

let protocol_version_from_body body_str =
  try
    let json = Yojson.Safe.from_string body_str in
    match Mcp_server.jsonrpc_request_of_yojson json with
    | Ok req when String.equal req.method_ "initialize" ->
        let version =
          Mcp_server.protocol_version_from_params req.params
          |> Mcp_server.normalize_protocol_version
        in
        Some version
    | _ -> None
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None

let is_http_error_response = Server_mcp_transport_http_headers.is_http_error_response

let request_runtime_result = Server_mcp_transport_http_headers.request_runtime_result

let request_force_json_response =
  Server_mcp_transport_http_headers.request_force_json_response

let allow_legacy_accept = Server_mcp_transport_http_headers.allow_legacy_accept

let classify_mcp_accept = Server_mcp_transport_http_headers.classify_mcp_accept

let classify_mcp_accept_for_body =
  Server_mcp_transport_http_headers.classify_mcp_accept_for_body

let should_use_sse_for_body =
  Server_mcp_transport_http_headers.should_use_sse_for_body

let legacy_accept_warning_headers =
  Server_mcp_transport_http_headers.legacy_accept_warning_headers

let legacy_transport_deprecation_headers =
  Server_mcp_transport_http_headers.legacy_transport_deprecation_headers

let force_json_response = Server_mcp_transport_http_headers.force_json_response
