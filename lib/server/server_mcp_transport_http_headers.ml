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
      id_is_null
      && (match code with
          | Some c ->
              (match Mcp_error_code.of_wire_code c with
               | Some ec -> Mcp_error_code.allows_null_request_id ec
               | None -> false)
          | None -> false)
  | _ -> false

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

let body_jsonrpc_method body_str =
  try
    match Yojson.Safe.from_string body_str with
    | `Assoc fields -> (
        match List.assoc_opt "method" fields with
        | Some (`String method_) -> Some (method_, List.mem_assoc "id" fields)
        | _ -> None)
    | _ -> None
  with Yojson.Json_error _ -> None

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

let body_required_name_for_method body_str method_ =
  let field_name =
    match method_ with
    | "tools/call" | "prompts/get" -> Some "name"
    | "resources/read" -> Some "uri"
    | _ -> None
  in
  match field_name with
  | None -> None
  | Some key -> (
      try
        match Yojson.Safe.from_string body_str with
        | `Assoc fields -> (
            match List.assoc_opt "params" fields with
            | Some (`Assoc params) -> (
                match List.assoc_opt key params with
                | Some (`String value) -> Some value
                | _ -> None)
            | _ -> None)
        | _ -> None
      with Yojson.Json_error _ -> None)

(* Three rejections that shared one string, and therefore one wire code. They
   answer different questions and MCP 2026-07-28 gives two of them their own
   codes, so the distinction lives in the type:

   - [Mirrored_header_mismatch] -- the body parsed and disagrees with a header.
     The request id is readable, so JSON-RPC 2.0 §5 requires echoing it.
   - [Unreadable_body] -- the header opted into the stateless revision but the
     body is not JSON. No id to echo; §5's null-id case.
   - [Unsupported_version] -- not a header disagreement at all. It has carried
     the mismatch code until now, so a client saw "your headers disagree" for a
     version this server simply does not speak. *)
type header_rejection =
  | Mirrored_header_mismatch of string
  | Unreadable_body of string
  | Unsupported_version of { requested : string }
  | Missing_required_meta of { key : string }

let header_mismatch msg = Error (Mirrored_header_mismatch msg)

let body_is_readable body_str =
  match Yojson.Safe.from_string body_str with
  | `Assoc _ -> true
  | _ | (exception Yojson.Json_error _) -> false

let validate_2026_request_headers request body_str =
  if not (request_uses_stateless_protocol request body_str) then Ok ()
  else
    match
      ( request_protocol_version_header request,
        Mcp_transport_protocol.protocol_version_from_request_meta_body body_str )
    with
    | None, _ ->
        header_mismatch "missing MCP-Protocol-Version header"
    | Some _, None when not (body_is_readable body_str) ->
        Error
          (Unreadable_body
             "MCP-Protocol-Version names a stateless revision but the body is \
              not a JSON object")
    (* A required _meta field being absent is not a header disagreement: the
       request is malformed, and 2026-07-28 answers that with -32602. It left
       as a mismatch until now. *)
    | Some _, None ->
        Error
          (Missing_required_meta
             { key = Mcp_transport_protocol.protocol_version_meta_key })
    | Some header_version, Some body_version
      when not (String.equal header_version body_version) ->
        header_mismatch
          (Printf.sprintf
             "MCP-Protocol-Version header value %S does not match body _meta \
              value %S"
             header_version body_version)
    | Some version, Some _
      when not (Mcp_transport_protocol.is_supported_protocol_version version) ->
        Error (Unsupported_version { requested = version })
    | Some _version, Some _
      when not
             (Mcp_transport_protocol.request_meta_has_key body_str
                Mcp_transport_protocol.client_capabilities_meta_key) ->
        Error
          (Missing_required_meta
             { key = Mcp_transport_protocol.client_capabilities_meta_key })
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

(* One rejection type, one place that turns it into a body. Both transports
   used to build this themselves and both wrote -32001 -- which is
   [Auth_error] here, so a client could not tell "your headers disagree" from
   "you are not authorized" from "this server does not speak that revision".
   MCP 2026-07-28 gives two of the three their own codes. *)
let request_id_of_body body_str =
  match Yojson.Safe.from_string body_str with
  | `Assoc fields -> List.assoc_opt "id" fields
  | _ | (exception Yojson.Json_error _) -> None

(* A rejection raised on a body that parsed answers a request whose id was
   read, and [Mcp_error_code.allows_null_request_id] already says so for both
   codes below. Falling back to [Invalid_request] is what carries the "the id
   itself is missing" case, which is the one JSON-RPC 2.0 §5 lets answer with
   a null id. *)
let echoing_request_id body_str code ~message =
  match request_id_of_body body_str with
  | Some id -> Mcp_error_code.jsonrpc_error_body_with_id code ~id ~message
  | None ->
    Mcp_error_code.jsonrpc_error_body Mcp_error_code.Invalid_request ~message

let header_rejection_body body_str = function
  | Mirrored_header_mismatch msg ->
    echoing_request_id body_str Mcp_error_code.Header_mismatch ~message:msg
  | Unreadable_body msg ->
    Mcp_error_code.jsonrpc_error_body Mcp_error_code.Invalid_request ~message:msg
  | Unsupported_version { requested } ->
    Mcp_error_code.unsupported_protocol_version_body ~requested
      ~supported:Mcp_transport_protocol.supported_protocol_versions
  (* The missing field is read out of a body that parsed, so the id is there
     to echo -- this arm used to answer [id: null] while
     [allows_null_request_id Invalid_params] said false, leaving a client with
     no way to match the rejection to the request it sent. *)
  | Missing_required_meta { key } ->
    echoing_request_id body_str Mcp_error_code.Invalid_params
      ~message:(Printf.sprintf "missing required params._meta.%s" key)

let should_use_sse_for_body (request : Httpun.Request.t) body_str accept_mode =
  match body_jsonrpc_method body_str with
  | Some (method_, _) when is_initialize_method method_ -> false
  | _ ->
      accept_mode = Http_negotiation.Streamable
      && Http_negotiation.accepts_sse_header
           (Httpun.Headers.get request.headers "accept")

let force_json_response = env_flag "MASC_FORCE_JSON_RESPONSE"

let sse_retry_ms = 3000

let sse_prime_event () =
  Printf.sprintf "retry: %d\n\n" sse_retry_ms

(* RFC-0089: SSE comment line + reconnect [retry:] directive, sourced from the
   [sse_retry_ms] SSOT. Stream priming sites (presence, activity) used to inline
   "retry: 3000", which would silently diverge from [sse_retry_ms] if the
   reconnect interval were ever tuned. *)
let sse_comment_with_retry ~comment =
  Printf.sprintf ": %s\nretry: %d\n\n" comment sse_retry_ms

let sse_ping_interval_s = 30.0

type last_event_id_error =
  | Malformed_last_event_id
  | Negative_last_event_id

let last_event_id_error_to_string = function
  | Malformed_last_event_id ->
      "Last-Event-ID must be a non-negative integer when supplied"
  | Negative_last_event_id ->
      "Last-Event-ID cannot be negative"

let get_last_event_id (request : Httpun.Request.t) =
  match Httpun.Headers.get request.headers "last-event-id" with
  | Some id -> (
      match int_of_string_opt id with
      | Some event_id when event_id >= 0 -> Ok (Some event_id)
      | Some _ -> Error Negative_last_event_id
      | None -> Error Malformed_last_event_id)
  | None -> Ok None

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
