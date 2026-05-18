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
  accept_warn_headers : (string * string) list;
}

type post_body_rejection =
  | Session_required of string
  | Unknown_session of string
  | Invalid_accept of string

let invalid_accept_message =
  "Invalid Accept header: must include application/json and text/event-stream. \
   Set MASC_ALLOW_LEGACY_ACCEPT=1 for temporary compatibility."

let decide_post_body ~request ~context ~session_is_known body_str =
  match
    Server_mcp_transport_http_protocol.validate_session_requirement
      ~session_was_provided:context.session_was_provided body_str
  with
  | Error msg -> Error (Session_required msg)
  | Ok () -> (
      let is_known = context.session_was_provided && session_is_known in
      match
        Server_mcp_transport_http_protocol.validate_session_known
          ~session_was_provided:context.session_was_provided ~is_known body_str
      with
      | Error msg -> Error (Unknown_session msg)
      | Ok () -> (
          match
            Server_mcp_transport_http_headers.classify_mcp_accept_for_body request
              body_str
          with
          | Mcp_transport_protocol.Http_negotiation.Rejected ->
              Error (Invalid_accept invalid_accept_message)
          | accept_mode ->
              let accept_warn_headers =
                Server_mcp_transport_http_headers.legacy_accept_warning_headers
                  accept_mode
              in
              Ok { body_str; accept_mode; accept_warn_headers }))
