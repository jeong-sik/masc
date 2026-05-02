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
      id_is_null && (code = Some (-32700) || code = Some (-32600))
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

let allow_legacy_accept = env_flag "MASC_ALLOW_LEGACY_ACCEPT"

let classify_mcp_accept (request : Httpun.Request.t) =
  Http_negotiation.classify_mcp_accept ~allow_legacy:allow_legacy_accept
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

let is_notification_method method_ =
  let prefix = "notifications/" in
  Base.String.is_prefix method_ ~prefix

let is_initialize_method method_ = String.equal method_ "initialize"

let request_accepts_json (request : Httpun.Request.t) =
  Http_negotiation.accepts_json
    (Httpun.Headers.get request.headers "accept")

let classify_mcp_accept_for_body (request : Httpun.Request.t) body_str =
  match classify_mcp_accept request with
  | Http_negotiation.Rejected -> (
      match body_jsonrpc_method body_str with
      | Some (method_, false) when is_notification_method method_ ->
          Http_negotiation.Legacy_accepted
      | _ -> Http_negotiation.Rejected)
  | accept_mode -> accept_mode

let should_use_sse_for_body (request : Httpun.Request.t) body_str accept_mode =
  match body_jsonrpc_method body_str with
  | Some (method_, _) when is_initialize_method method_ -> false
  | _ ->
      accept_mode = Http_negotiation.Streamable
      && Http_negotiation.accepts_sse_header
           (Httpun.Headers.get request.headers "accept")

let legacy_accept_warning_headers = function
  | Http_negotiation.Legacy_accepted ->
      [
        ( "warning",
          "299 - \"Legacy Accept is deprecated; use 'application/json, text/event-stream'\"" );
        ("x-masc-legacy-accept", "1");
      ]
  | Http_negotiation.Streamable | Http_negotiation.Rejected -> []

let legacy_transport_deprecation_headers =
  [
    ("deprecation", "true");
    ( "warning",
      "299 - \"Legacy SSE endpoints (/sse,/messages) are deprecated; use /mcp\"" );
    ("link", "</mcp>; rel=\"successor-version\"");
  ]

let force_json_response =
  env_flag "MASC_FORCE_JSON_RESPONSE" || env_flag "MCP_FORCE_JSON_RESPONSE"

let sse_retry_ms = 3000

let sse_prime_event () =
  let id = Sse.next_id () in
  Printf.sprintf "retry: %d\nid: %d\n\n" sse_retry_ms id

let sse_ping_interval_s = 30.0

let get_last_event_id (request : Httpun.Request.t) =
  match Httpun.Headers.get request.headers "last-event-id" with
  | Some id -> (
      int_of_string_opt (id))
  | None -> None

let mcp_headers session_id protocol_version =
  [ ("mcp-session-id", session_id); ("mcp-protocol-version", protocol_version) ]

let session_cookie_header session_id =
  ( "set-cookie",
    Printf.sprintf "mcp-session-id=%s; Path=/; Max-Age=%d; SameSite=Lax"
      session_id Masc_time_constants.day_int )

let sse_headers ~(deps : deps) session_id protocol_version origin =
  [
    ("content-type", Http_negotiation.sse_content_type);
    session_cookie_header session_id;
  ]
  @ mcp_headers session_id protocol_version
  @ deps.cors_headers origin

let sse_stream_headers ~(deps : deps) session_id protocol_version origin =
  [
    ("content-type", Http_negotiation.sse_content_type);
    ("cache-control", "no-cache");
    ("connection", "keep-alive");
    session_cookie_header session_id;
  ]
  @ mcp_headers session_id protocol_version
  @ deps.cors_headers origin

let json_headers ~(deps : deps) session_id protocol_version origin =
  [ ("content-type", "application/json") ]
  @ mcp_headers session_id protocol_version
  @ deps.cors_headers origin
