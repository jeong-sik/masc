module Http = Http_server_eio
module Http_negotiation = Mcp_transport_protocol.Http_negotiation

type deps = Server_mcp_transport_http_types.deps

let is_http_error_response = function
  | `Assoc fields ->
      let id_is_null =
        match List.assoc_opt "id" fields with
        | Some `Null -> true
        | _ -> false
      in
      let code =
        match List.assoc_opt "error" fields with
        | Some (`Assoc err_fields) -> (
            match List.assoc_opt "code" err_fields with
            | Some (`Int c) -> Some c
            | _ -> None)
        | _ -> None
      in
      let is_parse_or_invalid = function
        | Mcp_error_code.Parse_error | Invalid_request -> true
        | _ -> false
      in
      id_is_null
      && (match code with
          | Some c ->
              (match Mcp_error_code.of_wire_code c with
               | Some ec -> is_parse_or_invalid ec
               | None -> false)
          | None -> false)
  | _ -> false

let request_runtime_result (deps : deps) =
  deps.get_runtime_result ()

let env_flag name =
  match Sys.getenv_opt name with
  | Some raw -> (
      match String.lowercase_ascii (String.trim raw) with
      | "1" | "true" | "yes" | "on" -> true
      | _ -> false)
  | None -> false

let header_truthy_value value =
  match String.lowercase_ascii (String.trim value) with
  | "1" | "true" | "yes" | "on" -> true
  | _ -> false

let request_force_json_response (request : Httpun.Request.t) =
  match
    Server_mcp_transport_http_session.get_header_any_case request.headers
      "x-masc-force-json"
  with
  | Some value -> header_truthy_value value
  | None -> false

let classify_mcp_accept (request : Httpun.Request.t) =
  Http_negotiation.classify_mcp_accept
    (Httpun.Headers.get request.headers "accept")

type body_jsonrpc_method_error =
  | Body_jsonrpc_method_parse_error of string

let body_jsonrpc_method_error_to_string = function
  | Body_jsonrpc_method_parse_error message -> "json_parse_error: " ^ message
;;

let body_jsonrpc_method_result body_str =
  try
    match Yojson.Safe.from_string body_str with
    | `Assoc fields -> (
        match List.assoc_opt "method" fields with
        | Some (`String method_) -> Ok (Some (method_, List.mem_assoc "id" fields))
        | _ -> Ok None)
    | _ -> Ok None
  with
  | Yojson.Json_error message -> Error (Body_jsonrpc_method_parse_error message)

let body_jsonrpc_method body_str =
  match body_jsonrpc_method_result body_str with
  | Ok method_ -> method_
  | Error error ->
      Log.Server.warn
        "mcp-http body_jsonrpc_method failed: %s"
        (body_jsonrpc_method_error_to_string error);
      None

let body_jsonrpc_method_only body_str =
  match body_jsonrpc_method body_str with
  | Some (method_, _) -> Some method_
  | None -> None

let is_initialize_method method_ = String.equal method_ "initialize"

let request_protocol_version_header (request : Httpun.Request.t) =
  Server_mcp_transport_http_session.get_header_any_case request.headers
    "mcp-protocol-version"

let request_method_header (request : Httpun.Request.t) =
  Server_mcp_transport_http_session.get_header_any_case request.headers
    "mcp-method"

let request_name_header (request : Httpun.Request.t) =
  Server_mcp_transport_http_session.get_header_any_case request.headers
    "mcp-name"

let request_uses_stateless_protocol request body_str =
  match request_protocol_version_header request with
  | Some version when Mcp_transport_protocol.is_stateless_protocol_version version ->
      true
  | _ -> Mcp_transport_protocol.body_uses_stateless_protocol body_str

type body_required_name_error =
  | Body_required_name_parse_error of string

let body_required_name_error_to_string = function
  | Body_required_name_parse_error message -> "json_parse_error: " ^ message
;;

let body_required_name_for_method_result body_str method_ =
  let field_name =
    match method_ with
    | "tools/call" | "prompts/get" -> Some "name"
    | "resources/read" -> Some "uri"
    | _ -> None
  in
  match field_name with
  | None -> Ok None
  | Some key -> (
      try
        match Yojson.Safe.from_string body_str with
        | `Assoc fields -> (
            match List.assoc_opt "params" fields with
            | Some (`Assoc params) -> (
                match List.assoc_opt key params with
                | Some (`String value) -> Ok (Some value)
                | _ -> Ok None)
            | _ -> Ok None)
        | _ -> Ok None
      with
      | Yojson.Json_error message -> Error (Body_required_name_parse_error message))

let body_required_name_for_method body_str method_ =
  match body_required_name_for_method_result body_str method_ with
  | Ok value -> value
  | Error error ->
      Log.Server.warn
        "mcp-http body_required_name_for_method failed: %s"
        (body_required_name_error_to_string error);
      None

let header_mismatch msg = Error ("HeaderMismatch: " ^ msg)

let validate_2026_request_headers request body_str =
  if not (request_uses_stateless_protocol request body_str) then Ok ()
  else
    match
      ( request_protocol_version_header request,
        Mcp_transport_protocol.protocol_version_from_request_meta_body body_str )
    with
    | None, _ ->
        header_mismatch "missing MCP-Protocol-Version header"
    | Some _, None ->
        header_mismatch
          ("missing params._meta."
         ^ Mcp_transport_protocol.protocol_version_meta_key)
    | Some header_version, Some body_version
      when not (String.equal header_version body_version) ->
        header_mismatch
          (Printf.sprintf
             "MCP-Protocol-Version header value %S does not match body _meta \
              value %S"
             header_version body_version)
    | Some version, Some _ when not (Mcp_transport_protocol.is_supported_protocol_version version) ->
        Error
          (Printf.sprintf "Unsupported protocol version %S (supported: %s)"
             version
             (String.concat ", "
                Mcp_transport_protocol.supported_protocol_versions))
    | Some _version, Some _ -> (
        match body_jsonrpc_method_only body_str with
        | None -> Ok ()
        | Some method_ -> (
            match request_method_header request with
            | None -> header_mismatch "missing Mcp-Method header"
            | Some header_method when not (String.equal header_method method_) ->
                header_mismatch
                  (Printf.sprintf
                     "Mcp-Method header value %S does not match body method %S"
                     header_method method_)
            | Some _ -> (
                match body_required_name_for_method body_str method_ with
                | None when
                    String.equal method_ "tools/call"
                    || String.equal method_ "resources/read"
                    || String.equal method_ "prompts/get" ->
                    header_mismatch
                      "missing body params.name or params.uri for required Mcp-Name"
                | None -> Ok ()
                | Some body_name -> (
                    match request_name_header request with
                    | None -> header_mismatch "missing Mcp-Name header"
                    | Some header_name when not (String.equal header_name body_name) ->
                        header_mismatch
                          (Printf.sprintf
                             "Mcp-Name header value %S does not match body \
                              value %S"
                             header_name body_name)
                    | Some _ -> Ok ()))))

let should_use_sse_for_body (request : Httpun.Request.t) body_str accept_mode =
  match body_jsonrpc_method body_str with
  | Some (method_, _) when is_initialize_method method_ -> false
  | _ ->
      accept_mode = Http_negotiation.Streamable
      && Http_negotiation.accepts_sse_header
           (Httpun.Headers.get request.headers "accept")

let force_json_response =
  env_flag "MASC_FORCE_JSON_RESPONSE" || env_flag "MCP_FORCE_JSON_RESPONSE"

let sse_retry_ms = 3000

let sse_prime_event () =
  let id = Sse.next_id () in
  Printf.sprintf "retry: %d\nid: %d\n\n" sse_retry_ms id

(* RFC-0089: SSE comment line + reconnect [retry:] directive, sourced from the
   [sse_retry_ms] SSOT. Stream priming sites (presence, activity) used to inline
   "retry: 3000", which would silently diverge from [sse_retry_ms] if the
   reconnect interval were ever tuned. *)
let sse_comment_with_retry ~comment =
  Printf.sprintf ": %s\nretry: %d\n\n" comment sse_retry_ms

let sse_ping_interval_s = 30.0

let get_last_event_id (request : Httpun.Request.t) =
  match Httpun.Headers.get request.headers "last-event-id" with
  | Some id -> (
      int_of_string_opt (id))
  | None -> None

let mcp_headers session_id protocol_version =
  if Mcp_transport_protocol.is_stateless_protocol_version protocol_version then
    [ ("mcp-protocol-version", protocol_version) ]
  else
    [ ("mcp-session-id", session_id); ("mcp-protocol-version", protocol_version) ]

let session_cookie_header session_id =
  ( "set-cookie",
    Printf.sprintf "mcp-session-id=%s; Path=/; Max-Age=%d; SameSite=Lax"
      session_id Masc_time_constants.day_int )

let session_cookie_headers protocol_version session_id =
  if Mcp_transport_protocol.is_stateless_protocol_version protocol_version then []
  else [ session_cookie_header session_id ]

let sse_headers ~(deps : deps) session_id protocol_version origin =
  [ ("content-type", Http_negotiation.sse_content_type) ]
  @ session_cookie_headers protocol_version session_id
  @ mcp_headers session_id protocol_version
  @ deps.cors_headers origin

let sse_stream_headers ~(deps : deps) session_id protocol_version origin =
  [
    ("content-type", Http_negotiation.sse_content_type);
    ("cache-control", "no-cache");
    ("connection", "keep-alive");
  ]
  @ session_cookie_headers protocol_version session_id
  @ mcp_headers session_id protocol_version
  @ deps.cors_headers origin

let json_headers ~(deps : deps) session_id protocol_version origin =
  [ ("content-type", "application/json") ]
  @ mcp_headers session_id protocol_version
  @ deps.cors_headers origin
