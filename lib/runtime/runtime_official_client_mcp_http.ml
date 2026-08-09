type phase =
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
  { mutable phase : phase
  ; mutable authenticated_requests : int
  ; mutable rejected_requests : int
  ; mutable tool_calls : int
  ; mutable negotiated_protocol_version : string option
  }

type t =
  { endpoint : string
  ; server_name : string
  ; authorization : string
  ; state : mutable_state
  ; state_mutex : Eio.Mutex.t
  ; dispatch_mutex : Eio.Mutex.t
  }

let max_body_bytes = 1024 * 1024

let hex_of_bytes bytes =
  let alphabet = "0123456789abcdef" in
  let length = Bytes.length bytes in
  let result = Bytes.create (length * 2) in
  for index = 0 to length - 1 do
    let value = Char.code (Bytes.get bytes index) in
    Bytes.set result (index * 2) alphabet.[value lsr 4];
    Bytes.set result ((index * 2) + 1) alphabet.[value land 0x0f]
  done;
  Bytes.unsafe_to_string result
;;

let fresh_capabilities secure_random =
  let entropy = Bytes.create 48 in
  Eio.Flow.read_exact secure_random entropy;
  let path_id = Bytes.sub entropy 0 16 |> hex_of_bytes in
  let token = Bytes.sub entropy 16 32 |> hex_of_bytes in
  path_id, token
;;

let snapshot t =
  Eio.Mutex.use_ro t.state_mutex (fun () ->
    { phase = t.state.phase
    ; authenticated_requests = t.state.authenticated_requests
    ; rejected_requests = t.state.rejected_requests
    ; tool_calls = t.state.tool_calls
    ; negotiated_protocol_version = t.state.negotiated_protocol_version
    })
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

let initialize_protocol_version = function
  | Some (`Assoc fields) ->
    (match List.assoc_opt "result" fields with
     | Some (`Assoc result_fields) ->
       (match List.assoc_opt "protocolVersion" result_fields with
        | Some (`String value) -> Some value
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let phase_error phase method_ =
  let expected =
    match phase with
    | Awaiting_initialize -> "initialize"
    | Awaiting_initialized -> "notifications/initialized"
    | Ready -> "tools/list or tools/call"
  in
  Printf.sprintf "MCP method %S is not valid before %s" method_ expected
;;

let phase_admits phase method_ request_id =
  match method_ with
  | "server/discover" | "initialize" ->
    phase = Awaiting_initialize && Option.is_some request_id
  | "notifications/initialized" ->
    phase = Awaiting_initialized && Option.is_none request_id
  | "tools/list" | "tools/call" -> phase = Ready && Option.is_some request_id
  | _ -> true
;;

let request_id_json = function
  | Some id -> id
  | None -> `Null
;;

let dispatch t ~tool_specs ~call_tool raw_message =
  Eio.Mutex.use_rw ~protect:true t.dispatch_mutex (fun () ->
    match Runtime_official_client_mcp.decode_message raw_message with
    | Error error -> Error (`Dispatch error)
    | Ok message ->
      let method_ = Runtime_official_client_mcp.message_method message in
      let request_id = Runtime_official_client_mcp.message_request_id message in
      let phase = Eio.Mutex.use_ro t.state_mutex (fun () -> t.state.phase) in
      if not (phase_admits phase method_ request_id)
      then
        Error
          (`Protocol
            (request_id_json request_id, phase_error phase method_))
      else
        (match
           Runtime_official_client_mcp.dispatch_message
             ~server_name:t.server_name
             ~tool_specs
             ~call_tool
             message
         with
         | Error error -> Error (`Dispatch error)
         | Ok result ->
           Eio.Mutex.use_rw ~protect:true t.state_mutex (fun () ->
             (match t.state.phase, method_, result.response with
              | Awaiting_initialize, "initialize", Some _ ->
                t.state.phase <- Awaiting_initialized;
                t.state.negotiated_protocol_version <-
                  initialize_protocol_version result.response
              | Awaiting_initialized, "notifications/initialized", None ->
                t.state.phase <- Ready
              | _ -> ());
             if result.tool_called
             then t.state.tool_calls <- t.state.tool_calls + 1);
           Ok result))
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

let content_type_is_json request =
  match Cohttp.Header.get_multi (Cohttp.Request.headers request) "content-type" with
  | [ value ] ->
    let media_type =
      match String.index_opt value ';' with
      | None -> value
      | Some index -> String.sub value 0 index
    in
    String.equal (String.trim media_type |> String.lowercase_ascii) "application/json"
  | [] | _ :: _ :: _ -> false
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
  match dispatch t ~tool_specs ~call_tool body with
  | Error (`Protocol (id, detail)) ->
    reject t;
    respond_json `Conflict (protocol_error_response id (-32002) detail)
  | Error (`Dispatch { kind; stage; detail }) ->
    reject t;
    let code =
      match kind with
      | Runtime_official_client_mcp.Json_parse -> -32700
      | Runtime_official_client_mcp.Protocol -> -32600
    in
    respond_json
      `Bad_request
      (protocol_error_response `Null code (stage ^ ": " ^ detail))
  | Ok { response = None; _ } -> respond `Accepted ""
  | Ok { response = Some response; _ } ->
    let protocol_version = (snapshot t).negotiated_protocol_version in
    respond_json ?protocol_version `OK response
;;

let handle_post t ~tool_specs ~call_tool request body =
  if not (content_type_is_json request)
  then (
    reject t;
    respond `Unsupported_media_type "Content-Type must be application/json")
  else
    match content_length request with
    | Error detail ->
      reject t;
      respond `Bad_request detail
    | Ok (Some length) when length > max_body_bytes ->
      reject t;
      respond `Payload_too_large "MCP request body exceeds 1048576 bytes"
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
         respond `Payload_too_large "MCP request body exceeds 1048576 bytes"
       | _ ->
         reject t;
         respond `Bad_request "failed to read MCP request body")
;;

let request_handler t ~path ~tool_specs ~call_tool _client_addr request body =
  if not (String.equal (Uri.path (Cohttp.Request.uri request)) path)
  then respond `Not_found "Not found"
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
    | `GET -> respond `Method_not_allowed "SSE is not enabled for this endpoint"
    | `DELETE -> respond `No_content ""
    | _ -> respond `Method_not_allowed "Method not allowed")
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
    { phase = Awaiting_initialize
    ; authenticated_requests = 0
    ; rejected_requests = 0
    ; tool_calls = 0
    ; negotiated_protocol_version = None
    }
  in
  let t =
    { endpoint = Printf.sprintf "http://127.0.0.1:%d%s" port path
    ; server_name
    ; authorization
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
