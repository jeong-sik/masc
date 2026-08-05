type post_body_decision = {
  body_str : string;
  accept_mode : Mcp_transport_protocol.Http_negotiation.accept_mode;
}

type post_body_rejection =
  | Invalid_accept of string
  | Header_mismatch of string
  | Unsupported_protocol_version of string

val invalid_accept_message : string

val decide_post_body :
  request:Httpun.Request.t ->
  string ->
  (post_body_decision, post_body_rejection) result
