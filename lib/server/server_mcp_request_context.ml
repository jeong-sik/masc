type t = {
  session_id : string;
  session_was_provided : bool;
  auth_token : string option;
  protocol_version : string;
  origin : string;
  base_path : string;
}

let make ~session_id_opt ~generated_session_id ~auth_token ~protocol_version
    ~origin ~base_path =
  let session_was_provided = Option.is_some session_id_opt in
  (* NDT-OK: HTTP ingress supplies [generated_session_id] only when the client
     omitted Mcp-Session-Id; persisted state still records the resolved value. *)
  let session_id = Option.value ~default:generated_session_id session_id_opt in
  { session_id; session_was_provided; auth_token; protocol_version; origin; base_path }

type post_body_decision = {
  body_str : string;
  accept_mode : Mcp_transport_protocol.Http_negotiation.accept_mode;
}

type post_body_rejection =
  | Parse_error of string
  | Session_required of string
  | Unknown_session of string
  | Invalid_accept of string
  | Header_mismatch of string

let invalid_accept_message =
  "Invalid Accept header: must include application/json and text/event-stream."

let body_json_parse_error body_str =
  match Yojson.Safe.from_string body_str with
  | _ -> None
  | exception Yojson.Json_error msg ->
      Some ("Invalid JSON request body: " ^ msg)

let decide_post_body ~request ~context ~session_is_known body_str =
  match body_json_parse_error body_str with
  | Some msg -> Error (Parse_error msg)
  | None ->
      let stateless_request =
        Server_mcp_transport_http_protocol.request_uses_stateless_protocol
          request body_str
      in
      let session_gate =
        if stateless_request then Ok ()
        else
          Server_mcp_transport_http_protocol.validate_session_requirement
            ~session_was_provided:context.session_was_provided body_str
      in
      match session_gate with
      | Error msg -> Error (Session_required msg)
      | Ok () -> (
          let is_known = context.session_was_provided && session_is_known in
          let known_gate =
            if stateless_request then Ok ()
            else
              Server_mcp_transport_http_protocol.validate_session_known
                ~session_was_provided:context.session_was_provided ~is_known
                body_str
          in
          match known_gate with
          | Error msg -> Error (Unknown_session msg)
          | Ok () -> (
              match
                Server_mcp_transport_http_protocol.validate_2026_request_headers
                  request body_str
              with
              | Error msg -> Error (Header_mismatch msg)
              | Ok () -> (
                  match
                    Server_mcp_transport_http_headers.classify_mcp_accept
                      request
                  with
                  | Mcp_transport_protocol.Http_negotiation.Rejected ->
                      Error (Invalid_accept invalid_accept_message)
                  | accept_mode -> Ok { body_str; accept_mode })))
