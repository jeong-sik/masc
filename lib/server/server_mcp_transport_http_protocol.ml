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
  is_ready : unit -> bool;
  get_runtime_result :
    unit -> (Server_mcp_transport_http_types.runtime, string) result;
  get_mcp_http_transport :
    unit -> (Server_mcp_transport_http_sse_owner.t, string) result;
  get_base_path : unit -> string;
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
  else if Mcp_transport_protocol.body_uses_stateless_protocol body_str then Ok ()
  else
    match method_from_body body_str with
    | Some "initialize" | Some "notifications/initialized" | Some "ping"
    | Some "server/discover" ->
        Ok ()
    | Some _ | None ->
        Error
          "Mcp-Session-Id header required. Call initialize first to obtain a \
           session."

(** Reject every client-supplied [Mcp-Session-Id] for which the server has no
    state. Session identifiers are server-issued capabilities: an initial
    [initialize] omits the header, then the server returns the identifier to
    use on subsequent requests. Accepting an unknown supplied identifier for
    selected methods would let a deleted session id be recreated while an
    earlier DELETE is still retiring its transport resources. *)
let validate_session_known ~session_was_provided ~is_known _body_str =
  if not session_was_provided then Ok ()
  else if is_known then Ok ()
  else
    Error
      "Unknown Mcp-Session-Id. The server has no state for the supplied \
       session id. Retry initialize without the Mcp-Session-Id header."

let protocol_version_from_body = Mcp_transport_protocol.protocol_version_from_body

let is_http_error_response = Server_mcp_transport_http_headers.is_http_error_response

let request_runtime_result = Server_mcp_transport_http_headers.request_runtime_result

let request_force_json_response =
  Server_mcp_transport_http_headers.request_force_json_response

let classify_mcp_accept = Server_mcp_transport_http_headers.classify_mcp_accept

let request_uses_stateless_protocol =
  Server_mcp_transport_http_headers.request_uses_stateless_protocol

let validate_2026_request_headers =
  Server_mcp_transport_http_headers.validate_2026_request_headers

let should_use_sse_for_body =
  Server_mcp_transport_http_headers.should_use_sse_for_body

let force_json_response = Server_mcp_transport_http_headers.force_json_response
