type t = {
  session_id : string;
  session_was_provided : bool;
  auth_token : string option;
  protocol_version : string;
  origin : string;
  base_path : string;
}

val make :
  session_id_opt:string option ->
  generated_session_id:string ->
  auth_token:string option ->
  protocol_version:string ->
  origin:string ->
  base_path:string ->
  t

type post_body_decision = {
  body_str : string;
  accept_mode : Mcp_transport_protocol.Http_negotiation.accept_mode;
  accept_warn_headers : (string * string) list;
}

type post_body_rejection =
  | Session_required of string
  | Unknown_session of string
  | Invalid_accept of string

val invalid_accept_message : string

val decide_post_body :
  request:Httpun.Request.t ->
  context:t ->
  session_is_known:bool ->
  string ->
  (post_body_decision, post_body_rejection) result
