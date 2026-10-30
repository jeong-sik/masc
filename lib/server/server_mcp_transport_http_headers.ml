module Http = Http_server_eio
module Http_negotiation = Mcp_transport_protocol.Http_negotiation

type deps = Server_mcp_transport_http_types.deps

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

let header_selects_per_request_protocol (request : Httpun.Request.t) =
  Httpun.Headers.get_multi request.headers "mcp-protocol-version"
  |> List.exists (fun version ->
       Mcp_transport_protocol.is_stateless_protocol_version version
       || not (Mcp_transport_protocol.is_supported_protocol_version version))

let request_uses_stateless_protocol request body_str =
  header_selects_per_request_protocol request
  || Option.is_some
       (Mcp_transport_protocol.protocol_version_from_request_meta_body body_str)

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
   - [Unreadable_body] -- valid JSON, but not a request object.
   - [Malformed_json] -- invalid JSON; JSON-RPC requires a parse error.
   - [Unsupported_version] -- not a header disagreement at all. It has carried
     the mismatch code until now, so a client saw "your headers disagree" for a
     version this server simply does not speak. *)
type header_rejection =
  | Mirrored_header_mismatch of string
  | Unreadable_body of string
  | Malformed_json of string
  | Unsupported_version of { requested : string }
  | Missing_required_meta of { key : string }
  | Invalid_request_envelope of string
  | Invalid_request_meta of string

let header_mismatch msg = Error (Mirrored_header_mismatch msg)

let classify_body body_str =
  match Yojson.Safe.from_string body_str with
  | `Assoc _ -> `Object
  | _ -> `Non_object
  | exception Yojson.Json_error _ -> `Malformed

let validate_2026_header_mirrors request body_str =
  if not (request_uses_stateless_protocol request body_str) then Ok ()
  else if
    List.exists
      (fun name ->
        match Httpun.Headers.get_multi request.Httpun.Request.headers name with
        | [] | [ _ ] -> false
        | _ :: _ :: _ -> true)
      [ "mcp-protocol-version"; "mcp-method"; "mcp-name" ]
  then header_mismatch "duplicate MCP routing header"
  else
    match
      ( request_protocol_version_header request,
        Mcp_transport_protocol.protocol_version_from_request_meta_body body_str )
    with
    | None, _ ->
        header_mismatch "missing MCP-Protocol-Version header"
    | Some _, None when classify_body body_str = `Malformed ->
        Error (Malformed_json "Invalid JSON")
    | Some _, None when classify_body body_str = `Non_object ->
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
             (Mcp_transport_protocol.request_meta_has_object body_str
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
                    match Option.map Mcp_transport_protocol.decode_header_value
                            (request_name_header request) with
                    | None -> header_mismatch "missing Mcp-Name header"
                    | Some (Error detail) ->
                        header_mismatch ("invalid Mcp-Name header: " ^ detail)
                    | Some (Ok header_name) when not (String.equal header_name body_name) ->
                        header_mismatch
                          (Printf.sprintf
                             "Mcp-Name header value %S does not match body \
                              value %S"
                             header_name body_name)
                    | Some (Ok _) -> Ok ()))))

let validate_2026_request_envelope body_str =
  let invalid () = Error (Invalid_request_envelope "Invalid JSON-RPC request") in
  match Yojson.Safe.from_string body_str with
  | json when Mcp_transport_protocol.is_jsonrpc_v2 json
              && Mcp_transport_protocol.has_unique_jsonrpc_fields json ->
    (match Mcp_transport_protocol.jsonrpc_request_of_yojson json with
     | Error _ -> invalid ()
     | Ok req when Mcp_transport_protocol.is_notification req -> Ok ()
     | Ok req when not (Mcp_transport_protocol.is_valid_request_id
                          (Mcp_transport_protocol.get_id req)) -> invalid ()
     | Ok req ->
       (match Mcp_transport_protocol.classify_request_protocol
                ~require_stateless:true ~method_:req.method_ ~params:req.params with
        | Ok (Mcp_transport_protocol.Legacy_protocol | Stateless_protocol _) -> Ok ()
        | Error (Mcp_transport_protocol.Invalid_request_meta message) ->
          Error (Invalid_request_meta message)
        | Error (Mcp_transport_protocol.Unsupported_request_version requested) ->
          Error (Unsupported_version { requested })))
  | _ | exception Yojson.Json_error _ -> invalid ()

let validate_2026_request_headers request body_str =
  match validate_2026_header_mirrors request body_str with
  | Error rejection -> Error rejection
  | Ok () when request_uses_stateless_protocol request body_str ->
    validate_2026_request_envelope body_str
  | Ok () -> Ok ()

(* One rejection type, one place that turns it into a body. Both transports
   used to build this themselves and both wrote -32001 -- which is
   [Auth_error] here, so a client could not tell "your headers disagree" from
   "you are not authorized" from "this server does not speak that revision".
   MCP 2026-07-28 gives two of the three their own codes. *)
let header_rejection_body body_str rejection =
  let body =
    match rejection with
    | Mirrored_header_mismatch msg ->
      Mcp_error_code.jsonrpc_error_body Mcp_error_code.Header_mismatch ~message:msg
    | Unreadable_body msg ->
      Mcp_error_code.jsonrpc_error_body Mcp_error_code.Invalid_request ~message:msg
    | Malformed_json msg ->
      Mcp_error_code.jsonrpc_error_body Mcp_error_code.Parse_error ~message:msg
    | Unsupported_version { requested } ->
      Mcp_error_code.unsupported_protocol_version_body ~requested
        ~supported:Mcp_transport_protocol.supported_protocol_versions
    | Missing_required_meta { key } ->
      Mcp_error_code.jsonrpc_error_body Mcp_error_code.Invalid_params
        ~message:(Printf.sprintf "missing or invalid required params._meta.%s" key)
    | Invalid_request_envelope message ->
      Mcp_error_code.jsonrpc_error_body Mcp_error_code.Invalid_request ~message
    | Invalid_request_meta message ->
      Mcp_error_code.jsonrpc_error_body Mcp_error_code.Invalid_params ~message
  in
  Server_mcp_transport_http_session.correlate_error_body_to_request
    ~request_body:body_str body

let modern_response_http_error_status ~request ~body_str response =
  if not (request_uses_stateless_protocol request body_str) then None
  else
    match response with
    | `Assoc fields ->
      (match List.assoc_opt "error" fields with
       | Some (`Assoc error) ->
         (match List.assoc_opt "code" error with
          | Some (`Int (-32601)) -> Some `Not_found
          | Some (`Int (-32700 | -32600 | -32602 | -32020 | -32021 | -32022)) ->
            Some `Bad_request
          | Some _ | None -> None)
       | Some _ | None -> None)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None

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
