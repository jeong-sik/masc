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
      (match code with
       | Some c -> (
           match Mcp_error_code.of_wire_code c with
           | Some (Parse_error | Invalid_request) -> id_is_null
           | Some Method_not_found -> true
           | Some _ | None -> false)
       | None -> false)
  | _ -> false

let is_method_not_found_response = function
  | `Assoc fields -> (
      match List.assoc_opt "error" fields with
      | Some (`Assoc error_fields) -> (
          match List.assoc_opt "code" error_fields with
          | Some (`Int (-32601)) -> true
          | _ -> false)
      | _ -> false)
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
  match Httpun.Headers.get request.headers "x-masc-force-json" with
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

let jsonrpc_id_or_null body_str =
  try
    match Yojson.Safe.from_string body_str with
    | `Assoc fields ->
        (match List.assoc_opt "id" fields with
         | Some id ->
             (match Mcp_transport_protocol.request_id_of_yojson id with
              | Ok request_id ->
                  Mcp_transport_protocol.request_id_to_yojson request_id
              | Error _ -> `Null)
         | None -> `Null)
    | _ -> `Null
  with Yojson.Json_error _ -> `Null
;;

let request_protocol_version_header (request : Httpun.Request.t) =
  Httpun.Headers.get request.headers "mcp-protocol-version"

let unsupported_protocol_version_header request =
  match request_protocol_version_header request with
  | Some version
    when not (Mcp_transport_protocol.is_supported_protocol_version version) ->
      Some version
  | Some _ | None -> None

let unsupported_protocol_version_error_body ?id requested =
  let response_id =
    match id with
    | Some ((`Int _ | `String _) as id) -> id
    | Some _ | None -> `Null
  in
  `Assoc
    [ ("jsonrpc", `String "2.0")
    ; ("id", response_id)
    ; ( "error"
      , `Assoc
          [ ("code", `Int (-32022))
          ; ("message", `String "Unsupported protocol version")
          ; ( "data"
            , `Assoc
                [ ( "supported"
                  , `List
                      (List.map
                         (fun version -> `String version)
                         Mcp_transport_protocol.supported_protocol_versions) )
                ; ("requested", `String requested)
                ] )
          ] )
    ]
  |> Yojson.Safe.to_string

let request_method_header (request : Httpun.Request.t) =
  Httpun.Headers.get request.headers "mcp-method"

let request_name_header (request : Httpun.Request.t) =
  Httpun.Headers.get request.headers "mcp-name"

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

let header_mismatch msg = Error ("HeaderMismatch: " ^ msg)

let validate_2026_request_headers request body_str =
  match Yojson.Safe.from_string body_str with
  | exception Yojson.Json_error _ -> Ok ()
  | _ ->
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

let should_use_sse_for_body (request : Httpun.Request.t) accept_mode =
  accept_mode = Http_negotiation.Streamable
  && Http_negotiation.accepts_sse_header
       (Httpun.Headers.get request.headers "accept")

(* MCP_FORCE_JSON_RESPONSE was retired (masc#25123 Wave 2):
   MASC_FORCE_JSON_RESPONSE is the single spelling, matching the MASC_*
   namespace every other knob uses. A set-but-ignored legacy spelling would
   silently change transport behavior for whoever still exports it, so it
   warns once at module init. *)
let () =
  if env_flag "MCP_FORCE_JSON_RESPONSE" then
    Log.Server.warn
      "retired env knob ignored env=MCP_FORCE_JSON_RESPONSE; use \
       MASC_FORCE_JSON_RESPONSE"

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

let mcp_headers protocol_version =
  [ ("mcp-protocol-version", protocol_version) ]

let sse_headers ~(deps : deps) protocol_version origin =
  [ ("content-type", Http_negotiation.sse_content_type) ]
  @ mcp_headers protocol_version
  @ deps.cors_headers origin

let sse_stream_headers ~(deps : deps) protocol_version origin =
  [
    ("content-type", Http_negotiation.sse_content_type);
    ("cache-control", "no-cache");
    ("connection", "keep-alive");
  ]
  @ mcp_headers protocol_version
  @ deps.cors_headers origin

let json_headers ~(deps : deps) protocol_version origin =
  [ ("content-type", "application/json") ]
  @ mcp_headers protocol_version
  @ deps.cors_headers origin
