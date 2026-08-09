type phase = Runtime_official_client_mcp.phase =
  | Awaiting_initialize
  | Awaiting_initialized
  | Ready

type snapshot =
  { phase : phase
  ; authenticated_requests : int
  ; rejected_requests : int
  ; tool_calls : int
  ; negotiated_protocol_version : string option
  }

type mutable_state =
  { mutable authenticated_requests : int
  ; mutable rejected_requests : int
  ; mutable tool_calls : int
  }

type t =
  { endpoint : string
  ; server_name : string
  ; authorization : string
  ; session : Runtime_official_client_mcp.session
  ; state : mutable_state
  ; state_mutex : Eio.Mutex.t
  ; dispatch_mutex : Eio.Mutex.t
  }

let max_body_bytes = 1024 * 1024

let hex_of_cstruct bytes =
  let alphabet = "0123456789abcdef" in
  let length = Cstruct.length bytes in
  let result = Bytes.create (length * 2) in
  for index = 0 to length - 1 do
    let value = Cstruct.get_uint8 bytes index in
    Bytes.set result (index * 2) alphabet.[value lsr 4];
    Bytes.set result ((index * 2) + 1) alphabet.[value land 0x0f]
  done;
  Bytes.unsafe_to_string result
;;

let fresh_capabilities secure_random =
  let entropy = Cstruct.create 48 in
  Eio.Flow.read_exact secure_random entropy;
  let path_id = Cstruct.sub entropy 0 16 |> hex_of_cstruct in
  let token = Cstruct.sub entropy 16 32 |> hex_of_cstruct in
  path_id, token
;;

let snapshot t =
  Eio.Mutex.use_ro t.dispatch_mutex (fun () ->
    let session = Runtime_official_client_mcp.snapshot_session t.session in
    Eio.Mutex.use_ro t.state_mutex (fun () ->
      { phase = session.phase
      ; authenticated_requests = t.state.authenticated_requests
      ; rejected_requests = t.state.rejected_requests
      ; tool_calls = t.state.tool_calls
      ; negotiated_protocol_version = session.negotiated_protocol_version
      }))
;;

let endpoint t = t.endpoint

let mcp_config_json t =
  `Assoc
    [ ( "mcpServers"
      , `Assoc
          [ ( t.server_name
            , `Assoc
                [ "url", `String t.endpoint
                ; ( "headers"
                  , `Assoc
                      [ "Authorization", `String ("Bearer " ^ t.authorization) ] )
                ] )
          ] )
    ]
;;

let headers ?protocol_version content_type =
  Cohttp.Header.of_list
    ([ "content-type", content_type; "cache-control", "no-store" ]
     @ Option.fold
         ~none:[]
         ~some:(fun version -> [ "mcp-protocol-version", version ])
         protocol_version)
;;

let respond ?protocol_version ?(content_type = "text/plain") status body =
  Cohttp_eio.Server.respond_string
    ~headers:(headers ?protocol_version content_type)
    ~status
    ~body
    ()
;;

let respond_json ?protocol_version status json =
  respond
    ?protocol_version
    ~content_type:"application/json"
    status
    (Yojson.Safe.to_string json)
;;

let protocol_error_response id code message =
  `Assoc
    [ "jsonrpc", `String "2.0"
    ; "id", id
    ; "error", `Assoc [ "code", `Int code; "message", `String message ]
    ]
;;

let dispatch t ~tool_specs ~call_tool message =
  Eio.Mutex.use_rw ~protect:true t.dispatch_mutex (fun () ->
    match
      Runtime_official_client_mcp.handle_message
        ~session:t.session
        ~server_name:t.server_name
        ~tool_specs
        ~call_tool
        message
    with
    | Error error -> Error error
    | Ok result ->
      if result.tool_called
      then
        Eio.Mutex.use_rw ~protect:true t.state_mutex (fun () ->
          t.state.tool_calls <- t.state.tool_calls + 1);
      Ok result)
;;

let update_state t f =
  Eio.Mutex.use_rw ~protect:true t.state_mutex (fun () -> f t.state)
;;

let reject t =
  update_state t (fun state -> state.rejected_requests <- state.rejected_requests + 1)
;;

let record_authenticated_request t =
  update_state t (fun state ->
    state.authenticated_requests <- state.authenticated_requests + 1)
;;

let authorization_matches t request =
  match Cohttp.Header.get_multi (Cohttp.Request.headers request) "authorization" with
  | [ value ] -> Eqaf.equal value ("Bearer " ^ t.authorization)
  | [] | _ :: _ :: _ -> false
;;

let origin_is_admitted request =
  match Cohttp.Header.get_multi (Cohttp.Request.headers request) "origin" with
  | [] -> true
  | _ :: _ -> false
;;

let accepts_streamable_mcp request =
  match Cohttp.Header.get_multi (Cohttp.Request.headers request) "accept" with
  | [] -> false
  | values ->
    Mcp_transport_protocol.Http_negotiation.accepts_streamable_mcp
      (Some (String.concat "," values))
;;

let content_type_is_json request =
  match Cohttp.Header.get_multi (Cohttp.Request.headers request) "content-type" with
  | [ value ] ->
    Mcp_transport_protocol.Http_negotiation.is_json_content_type (Some value)
  | [] | _ :: _ :: _ -> false
;;

let protocol_version_header t request =
  let values =
    Cohttp.Header.get_multi
      (Cohttp.Request.headers request)
      "mcp-protocol-version"
  in
  let session = Runtime_official_client_mcp.snapshot_session t.session in
  match session.phase, session.negotiated_protocol_version, values with
  | Awaiting_initialize, None, [] -> Ok ()
  | Awaiting_initialize, None, [ value ] ->
    Mcp_transport_protocol.validate_protocol_version value
    |> Result.map (fun _ -> ())
  | (Awaiting_initialized | Ready), Some expected, [ value ]
    when String.equal expected value -> Ok ()
  | (Awaiting_initialized | Ready), Some _, [] ->
    Error "missing MCP-Protocol-Version header"
  | (Awaiting_initialized | Ready), Some expected, [ value ] ->
    Error
      (Printf.sprintf
         "MCP-Protocol-Version mismatch: expected %S, got %S"
         expected
         value)
  | _, _, _ :: _ :: _ -> Error "duplicate MCP-Protocol-Version header"
  | Awaiting_initialize, Some _, _
  | (Awaiting_initialized | Ready), None, _ ->
    Error "MCP session has no negotiated protocol version"
;;

let content_length request =
  match Cohttp.Header.get_multi (Cohttp.Request.headers request) "content-length" with
  | [] -> Ok None
  | [ value ] ->
    (match int_of_string_opt (String.trim value) with
     | Some length when length >= 0 -> Ok (Some length)
     | _ -> Error "invalid Content-Length")
  | _ :: _ :: _ -> Error "duplicate Content-Length"
;;

let handle_message t ~tool_specs ~call_tool body =
  match
    try Ok (Yojson.Safe.from_string body) with
    | Yojson.Json_error detail -> Error detail
    | Stack_overflow -> Error "JSON nesting exceeds parser limits"
    | Failure detail -> Error detail
  with
  | Error detail ->
    reject t;
    respond_json
      `Bad_request
      (protocol_error_response `Null (-32700) ("MCP message: " ^ detail))
  | Ok message ->
    (match dispatch t ~tool_specs ~call_tool message with
     | Error { stage; detail } ->
       reject t;
       respond_json
         `Bad_request
         (protocol_error_response `Null (-32600) (stage ^ ": " ^ detail))
     | Ok { response = None; _ } -> respond `Accepted ""
     | Ok { response = Some response; _ } ->
       let protocol_version = (snapshot t).negotiated_protocol_version in
       respond_json ?protocol_version `OK response)
;;

let handle_post t ~tool_specs ~call_tool request body =
  if not (accepts_streamable_mcp request)
  then (
    reject t;
    respond
      `Not_acceptable
      "Accept must include application/json and text/event-stream")
  else if not (content_type_is_json request)
  then (
    reject t;
    respond `Unsupported_media_type "Content-Type must be application/json")
  else
    match protocol_version_header t request with
    | Error detail ->
      reject t;
      respond `Bad_request detail
    | Ok () ->
      (match content_length request with
       | Error detail ->
         reject t;
         respond `Bad_request detail
       | Ok (Some length) when length > max_body_bytes ->
         reject t;
         respond `Request_entity_too_large "MCP request body exceeds 1048576 bytes"
       | Ok _ ->
         (try
            let body =
              Eio.Buf_read.(of_flow ~max_size:max_body_bytes body |> take_all)
            in
            handle_message t ~tool_specs ~call_tool body
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | Eio.Buf_read.Buffer_limit_exceeded ->
            reject t;
            respond `Request_entity_too_large "MCP request body exceeds 1048576 bytes"
          | _ ->
            reject t;
            respond `Bad_request "failed to read MCP request body"))
;;

let request_handler t ~path ~tool_specs ~call_tool _client_addr request body =
  if not (String.equal (Uri.path (Cohttp.Request.uri request)) path)
  then respond `Not_found "Not found"
  else if not (origin_is_admitted request)
  then (
    reject t;
    respond `Forbidden "Origin is not admitted on the native-client endpoint")
  else if not (authorization_matches t request)
  then (
    reject t;
    Cohttp_eio.Server.respond_string
      ~headers:(Cohttp.Header.of_list [ "www-authenticate", "Bearer" ])
      ~status:`Unauthorized
      ~body:"Unauthorized"
      ())
  else (
    record_authenticated_request t;
    match Cohttp.Request.meth request with
    | `POST -> handle_post t ~tool_specs ~call_tool request body
    | `GET ->
      reject t;
      respond `Method_not_allowed "SSE is not enabled for this endpoint"
    | `DELETE ->
      reject t;
      respond `Method_not_allowed "Session deletion is not enabled"
    | _ ->
      reject t;
      respond `Method_not_allowed "Method not allowed")
;;

let start ~sw ~net ~secure_random ~server_name ~tool_specs ~call_tool () =
  let path_id, authorization = fresh_capabilities secure_random in
  let path = "/mcp/" ^ path_id in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~reuse_addr:false
      ~backlog:8
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix _ -> assert false
  in
  let state =
    { authenticated_requests = 0
    ; rejected_requests = 0
    ; tool_calls = 0
    }
  in
  let t =
    { endpoint = Printf.sprintf "http://127.0.0.1:%d%s" port path
    ; server_name
    ; authorization
    ; session = Runtime_official_client_mcp.create_session ()
    ; state
    ; state_mutex = Eio.Mutex.create ()
    ; dispatch_mutex = Eio.Mutex.create ()
    }
  in
  let server =
    Cohttp_eio.Server.make
      ~callback:(request_handler t ~path ~tool_specs ~call_tool)
      ()
  in
  Eio.Fiber.fork ~sw (fun () ->
    Cohttp_eio.Server.run
      socket
      server
      ~on_error:(fun _ ->
        Log.Runtime_agent.warn "official-client MCP HTTP connection failed"));
  t
;;
