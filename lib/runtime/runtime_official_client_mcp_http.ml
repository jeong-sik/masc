type snapshot =
  { phase : Runtime_official_client_mcp.phase
  ; authenticated_requests : int
  ; rejected_requests : int
  ; tool_calls : int
  ; connection_failures : int
  ; last_connection_error : string option
  ; listener_failure : string option
  ; negotiated_protocol_version : string option
  ; retained_tool_reservations : int
  }

type mutable_state =
  { mutable authenticated_requests : int
  ; mutable rejected_requests : int
  ; mutable tool_calls : int
  ; mutable connection_failures : int
  ; mutable last_connection_error : string option
  ; mutable listener_failure : string option
  }

(* Only unresolved physical promises remain in the scheduler. A cancelled
   queued Serial settles itself, while its unresolved predecessors remain in
   the flat barrier. No historical reservation graph is retained or traversed. *)
type tool_reservation =
  { predecessors : unit Eio.Promise.t list
  ; finish : unit -> unit
  }

type tool_schedule =
  { serial_barrier : unit Eio.Promise.t list
  ; concurrent : unit Eio.Promise.t list
  }

type tool_admission =
  | Admission_open
  | Admission_closed of Runtime_official_client_tool.host_stop

let unresolved promises = List.filter (fun promise -> Eio.Promise.peek promise=None) promises

type t =
  { endpoint : string
  ; server_name : string
  ; authorization : string
  ; session : Runtime_official_client_mcp.session
  ; state : mutable_state
  ; state_mutex : Eio.Mutex.t
  ; dispatch_mutex : Eio.Mutex.t
  ; mutable tool_schedule : tool_schedule
  ; mutable pending_reservations : unit Eio.Promise.t list
  ; mutable admission : tool_admission
  ; stop_response_boundary : unit Eio.Promise.t
  ; signal_stop_response_boundary : unit -> unit
  }

type tool_response =
  { outcome : Runtime_official_client_mcp.tool_result
  ; after_response_sent : unit -> unit
  ; stop : Runtime_official_client_tool.host_stop option
  }

let max_body_bytes = 1024 * 1024

(* Checked against the byte string 0..255: identical output, lowercase, no
   separators. Cstruct is already a dependency here. *)
let hex_of_cstruct = Cstruct.to_hex_string

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
      ; connection_failures = t.state.connection_failures
      ; last_connection_error = t.state.last_connection_error
      ; listener_failure = t.state.listener_failure
      ; negotiated_protocol_version = session.negotiated_protocol_version
      ; retained_tool_reservations = List.length t.pending_reservations
      }))
;;

type endpoint =
  { url : string
  ; headers : (string * string) list
  }

(* The one spelling of the header value: [endpoint] hands it to clients and
   [authorization_matches] compares requests against it. *)
let bearer_authorization t = "Bearer " ^ t.authorization

let endpoint t =
  { url = t.endpoint; headers = [ "Authorization", bearer_authorization t ] }
;;

let mcp_config_json t ~eager_tools =
  let { url; headers } = endpoint t in
  `Assoc
    [ ( "mcpServers"
      , `Assoc
          [ ( t.server_name
            , `Assoc
                [ "url", `String url
                ; ( "headers"
                  , `Assoc (List.map (fun (name, value) -> name, `String value) headers) )
                ; ( "tools"
                  , `Assoc
                      (List.map
                         (fun name -> name, `Assoc [ "eager", `Bool true ])
                         eager_tools) )
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

type dispatch_error =
  | Protocol_error of Runtime_official_client_mcp.error
  | Protocol_header_error of string
  | Tool_inventory_failed of exn
  | Tool_outcome_unknown of
      { id : Yojson.Safe.t
      ; name : string
      ; call_id : string
      ; cause : exn
      }

let prune_schedule t =
  t.tool_schedule <-
    { serial_barrier=unresolved t.tool_schedule.serial_barrier
    ; concurrent=unresolved t.tool_schedule.concurrent };
  t.pending_reservations <- unresolved t.pending_reservations

let reserve_tool t execution_mode =
  prune_schedule t;
  let settled, resolve = Eio.Promise.create () in
  let predecessors = match execution_mode with
    | Agent_core.Tool_contract.Concurrent -> t.tool_schedule.serial_barrier
    | Serial -> t.tool_schedule.serial_barrier @ t.tool_schedule.concurrent in
  let reservation = {predecessors;finish=(fun () ->
    Eio.Promise.resolve resolve ();
    (* Pure owner-domain cleanup: no lock or suspension can mask cancellation. *)
    prune_schedule t)} in
  t.pending_reservations <- settled :: t.pending_reservations;
  t.tool_schedule <- (match execution_mode with
    | Concurrent -> {t.tool_schedule with concurrent=settled :: t.tool_schedule.concurrent}
    | Serial -> {serial_barrier=settled :: predecessors;concurrent=[]});
  reservation
;;

let close_admission t stop =
  Eio.Cancel.protect (fun () ->
    Eio.Mutex.use_ro t.dispatch_mutex (fun () ->
      t.admission <- Admission_closed (match t.admission with
        | Admission_open -> stop
        | Admission_closed previous ->
          if Runtime_official_client_tool.host_stop_failed stop
             && not (Runtime_official_client_tool.host_stop_failed previous)
          then stop else previous)))
;;

let run_reserved t reservation ~on_stop call =
  Fun.protect ~finally:reservation.finish (fun () ->
    List.iter Eio.Promise.await reservation.predecessors;
    let response = call () in
    Option.iter (fun response -> Option.iter (fun stop ->
      on_stop ();
      close_admission t stop) response.stop) response;
    response)
;;

let await_host_stop t =
  Eio.Promise.await t.stop_response_boundary;
  let pending = Eio.Mutex.use_ro t.dispatch_mutex (fun () -> t.pending_reservations) in
  List.iter Eio.Promise.await pending;
  Eio.Mutex.use_ro t.dispatch_mutex (fun () -> match t.admission with
    | Admission_closed stop -> stop
    | Admission_open -> assert false)
;;

let turn_closed_result : Runtime_official_client_mcp.tool_result =
  { success=false
  ; content=Yojson.Safe.to_string (`Assoc
      ["execution", `String "not_started"; "reason", `String "turn_closed"])
  ; content_blocks=None }
;;

let dispatch t ~request ~tool_specs ~tool_execution_mode ~call_tool message =
  (* Core MCP validates its phase, call shape and argument object before
     guarded_call_tool. Reserve the producer schedule while still owning this
     short protocol lock, then release it before waiting or executing. The
     tools/call continuation only encodes its result and mutates no session. *)
  Eio.Mutex.lock t.dispatch_mutex;
  let response_boundary = ref (fun () -> ()) in
  let boundary_transferred = ref false in
  let locked = ref true in
  let release_protocol () =
    if !locked then begin locked := false; Eio.Mutex.unlock t.dispatch_mutex end in
  Fun.protect ~finally:(fun () ->
    release_protocol ();
    if not !boundary_transferred then !response_boundary ()) (fun () ->
    match protocol_version_header t request with
    | Error detail -> Error (Protocol_header_error detail)
    | Ok () ->
      let inventory_failure = ref None in
      let tool_failure = ref None in
      let after_response_sent = ref None in
      let guarded_tool_specs () =
        try tool_specs () with
        | exn when Keeper_operator_interrupt.is_operator_interrupt exn -> raise exn
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
          Llm_provider.Reserved_exn.reraise_if_reserved exn;
          inventory_failure := Some exn;
          raise exn
      in
      let guarded_call_tool ~name ~call_id ~arguments =
        try
          match tool_execution_mode ~name ~arguments with
          | None -> None
          | Some execution_mode ->
            (match t.admission with
             | Admission_closed _ -> Some turn_closed_result
             | Admission_open ->
               let reservation = reserve_tool t execution_mode in
               release_protocol ();
               match run_reserved t reservation
                   ~on_stop:(fun () -> response_boundary := t.signal_stop_response_boundary)
                   (fun () -> call_tool ~name ~call_id ~arguments) with
               | None -> None
               | Some response ->
                 after_response_sent := Some response.after_response_sent;
                 Some response.outcome)
        with
        | exn when Keeper_operator_interrupt.is_operator_interrupt exn -> raise exn
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
          Llm_provider.Reserved_exn.reraise_if_reserved exn;
          tool_failure := Some (name, call_id, exn);
          raise exn
      in
      try
        match
          Runtime_official_client_mcp.handle_message
            ~session:t.session
            ~server_name:t.server_name
            ~tool_call_policy:Allow_tool_calls
            ~tool_specs:guarded_tool_specs
            ~call_tool:guarded_call_tool
            message
        with
        | Error error -> Error (Protocol_error error)
        | Ok result ->
          if result.tool_called
          then
            Eio.Mutex.use_rw ~protect:true t.state_mutex (fun () ->
              t.state.tool_calls <- t.state.tool_calls + 1);
          boundary_transferred := true;
          Ok (result, !after_response_sent, !response_boundary)
      with
      | exn when Keeper_operator_interrupt.is_operator_interrupt exn -> raise exn
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Llm_provider.Reserved_exn.reraise_if_reserved exn;
        (match !tool_failure, !inventory_failure with
         | Some (name, call_id, cause), _ ->
           Error
             (Tool_outcome_unknown
                { id = `Null; name; call_id; cause })
         | None, Some cause -> Error (Tool_inventory_failed cause)
         | None, None -> Error (Tool_inventory_failed exn)))
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

let record_connection_failure t exn =
  let detail = Printexc.to_string exn in
  update_state t (fun state ->
    state.connection_failures <- state.connection_failures + 1;
    state.last_connection_error <- Some detail);
  Log.Runtime_agent.warn "official-client MCP HTTP connection failed: %s" detail
;;

let record_listener_failure t exn =
  let detail = Printexc.to_string exn in
  update_state t (fun state -> state.listener_failure <- Some detail);
  Log.Runtime_agent.error "official-client MCP HTTP listener failed: %s" detail
;;

let authorization_matches t request =
  match Cohttp.Header.get_multi (Cohttp.Request.headers request) "authorization" with
  | [ value ] -> Eqaf.equal value (bearer_authorization t)
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

let content_length request =
  match Cohttp.Header.get_multi (Cohttp.Request.headers request) "content-length" with
  | [] -> Ok None
  | [ value ] ->
    (match int_of_string_opt (String.trim value) with
     | Some length when length >= 0 -> Ok (Some length)
     | _ -> Error "invalid Content-Length")
  | _ :: _ :: _ -> Error "duplicate Content-Length"
;;

let handle_message t ~request ~tool_specs ~tool_execution_mode ~call_tool body =
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
    (match dispatch t ~request ~tool_specs ~tool_execution_mode ~call_tool message with
     | Error (Protocol_error { stage; detail }) ->
       reject t;
       respond_json
         `Bad_request
         (protocol_error_response `Null (-32600) (stage ^ ": " ^ detail))
     | Error (Protocol_header_error detail) ->
       reject t;
       respond `Bad_request detail
     | Error (Tool_inventory_failed exn) ->
       reject t;
       Log.Runtime_agent.error
         "official-client MCP tool inventory failed: %s"
         (Printexc.to_string exn);
       respond_json
         `Internal_server_error
         (protocol_error_response `Null (-32603) "MCP tool inventory unavailable")
     | Error (Tool_outcome_unknown { id; name; call_id; cause }) ->
       reject t;
       Log.Runtime_agent.error
         "official-client MCP tool outcome unknown (tool=%s call_id=%s error=%s)"
         name
         call_id
         (Printexc.to_string cause);
       respond_json
         `Internal_server_error
         (protocol_error_response
            id
            (-32603)
            (Tool_guidance.to_string Tool_guidance.Mcp_outcome_unknown))
     | Ok ({ response = None; _ }, _, boundary) ->
       boundary (); respond `Accepted ""
     | Ok ({ response = Some response; _ }, after_response_sent, boundary) ->
       (match
          let protocol_version = (snapshot t).negotiated_protocol_version in
          respond_json ?protocol_version `OK response
        with
        | response -> fun writer ->
          Fun.protect ~finally:boundary (fun () ->
            response writer;
            Option.iter (fun notify -> notify ()) after_response_sent)
        | exception exn -> boundary (); raise exn))
;;

let handle_post t ~tool_specs ~tool_execution_mode ~call_tool request body =
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
    match content_length request with
    | Error detail ->
      reject t;
      respond `Bad_request detail
    | Ok (Some length) when length > max_body_bytes ->
      reject t;
      respond `Request_entity_too_large "MCP request body exceeds 1048576 bytes"
    | Ok _ ->
      (match
         try
           Ok Eio.Buf_read.(of_flow ~max_size:max_body_bytes body |> take_all)
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | Eio.Buf_read.Buffer_limit_exceeded -> Error `Too_large
         | exn -> Error (`Read_failed exn)
       with
       | Error `Too_large ->
         reject t;
         respond `Request_entity_too_large "MCP request body exceeds 1048576 bytes"
       | Error (`Read_failed exn) ->
         reject t;
         Log.Runtime_agent.warn
           "official-client MCP request body read failed: %s"
           (Printexc.to_string exn);
         respond `Bad_request "failed to read MCP request body"
       | Ok body -> handle_message t ~request ~tool_specs ~tool_execution_mode ~call_tool body)
;;

let request_handler t ~path ~tool_specs ~tool_execution_mode ~call_tool _client_addr request body =
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
    | `POST -> handle_post t ~tool_specs ~tool_execution_mode ~call_tool request body
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

let start ~sw ~net ~secure_random ~server_name ~tool_specs ~tool_execution_mode ~call_tool () =
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
    ; connection_failures = 0
    ; last_connection_error = None
    ; listener_failure = None
    }
  in
  let stop_response_boundary, resolve_stop_response_boundary = Eio.Promise.create () in
  let boundary_signalled = Atomic.make false in
  let signal_stop_response_boundary () =
    if Atomic.compare_and_set boundary_signalled false true
    then Eio.Promise.resolve resolve_stop_response_boundary () in
  let t =
    { endpoint = Printf.sprintf "http://127.0.0.1:%d%s" port path
    ; server_name
    ; authorization
    ; session = Runtime_official_client_mcp.create_session ()
    ; state
    ; state_mutex = Eio.Mutex.create ()
    ; dispatch_mutex = Eio.Mutex.create ()
    ; tool_schedule = {serial_barrier=[];concurrent=[]}
    ; pending_reservations=[]
    ; admission=Admission_open
    ; stop_response_boundary
    ; signal_stop_response_boundary
    }
  in
  let server =
    Cohttp_eio.Server.make
      ~callback:(request_handler t ~path ~tool_specs ~tool_execution_mode ~call_tool)
      ()
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    (try
       Cohttp_eio.Server.run socket server ~on_error:(record_connection_failure t)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> record_listener_failure t exn);
    `Stop_daemon);
  t
;;

module For_testing = struct
  type snapshot =
    { phase : Runtime_official_client_mcp.phase
    ; authenticated_requests : int
    ; rejected_requests : int
    ; tool_calls : int
    ; connection_failures : int
    ; last_connection_error : string option
    ; listener_failure : string option
    ; negotiated_protocol_version : string option
    ; retained_tool_reservations : int
    }

  let snapshot t =
    let current = snapshot t in
    { phase = current.phase
    ; authenticated_requests = current.authenticated_requests
    ; rejected_requests = current.rejected_requests
    ; tool_calls = current.tool_calls
    ; connection_failures = current.connection_failures
    ; last_connection_error = current.last_connection_error
    ; listener_failure = current.listener_failure
    ; negotiated_protocol_version = current.negotiated_protocol_version
    ; retained_tool_reservations = current.retained_tool_reservations
    }
  ;;
end
