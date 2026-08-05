type post_body_decision = {
  body_str : string;
  accept_mode : Mcp_transport_protocol.Http_negotiation.accept_mode;
}

type post_body_rejection =
  | Invalid_accept of string
  | Header_mismatch of string
  | Unsupported_protocol_version of string

let invalid_accept_message =
  "Invalid Accept header: must include application/json and text/event-stream."

let decide_post_body ~request body_str =
  let header_version =
    Server_mcp_transport_http_headers.request_protocol_version_header request
  in
  match header_version with
  | Some header_version
    when not
           (Mcp_transport_protocol.is_supported_protocol_version
              header_version) ->
      Error (Unsupported_protocol_version header_version)
  | _ ->
  match Server_mcp_transport_http_protocol.validate_2026_request_headers request body_str with
  | Error msg -> Error (Header_mismatch msg)
  | Ok () -> (
      match Server_mcp_transport_http_headers.classify_mcp_accept request with
      | Mcp_transport_protocol.Http_negotiation.Rejected ->
          Error (Invalid_accept invalid_accept_message)
      | accept_mode -> Ok { body_str; accept_mode })
