type error =
  { stage : string
  ; detail : string
  }

type tool_result =
  { success : bool
  ; content : string
  }

type dispatch =
  { response : Yojson.Safe.t option
  ; tool_called : bool
  }

type phase =
  | Awaiting_initialize
  | Awaiting_initialized
  | Ready

type session_snapshot =
  { phase : phase
  ; negotiated_protocol_version : string option
  }

type lifecycle =
  | Needs_initialize
  | Needs_initialized of string
  | Session_ready of string

type session =
  { lifecycle : lifecycle Atomic.t
  }

type message =
  { method_name : string
  ; request_id : Mcp_transport_protocol.request_id option
  ; params : Yojson.Safe.t
  }

let ( let* ) = Result.bind
let error stage detail = Error { stage; detail }

let create_session () = { lifecycle = Atomic.make Needs_initialize }

let phase_of_lifecycle = function
  | Needs_initialize -> Awaiting_initialize
  | Needs_initialized _ -> Awaiting_initialized
  | Session_ready _ -> Ready
;;

let protocol_version_of_lifecycle = function
  | Needs_initialize -> None
  | Needs_initialized version | Session_ready version -> Some version
;;

let snapshot_session session =
  let lifecycle = Atomic.get session.lifecycle in
  { phase = phase_of_lifecycle lifecycle
  ; negotiated_protocol_version = protocol_version_of_lifecycle lifecycle
  }
;;

let phase_to_string = function
  | Awaiting_initialize -> "awaiting_initialize"
  | Awaiting_initialized -> "awaiting_initialized"
  | Ready -> "ready"
;;

let require_phase session ~stage expected =
  let actual = Atomic.get session.lifecycle |> phase_of_lifecycle in
  if actual = expected
  then Ok ()
  else
    error
      stage
      (Printf.sprintf
         "MCP session phase is %s; expected %s"
         (phase_to_string actual)
         (phase_to_string expected))
;;

let transition_initialize session ~stage protocol_version =
  let current = Atomic.get session.lifecycle in
  match current with
  | Needs_initialize ->
    if Atomic.compare_and_set
         session.lifecycle
         current
         (Needs_initialized protocol_version)
    then Ok ()
    else
      let actual = Atomic.get session.lifecycle |> phase_of_lifecycle in
      error
        stage
        (Printf.sprintf
           "MCP session phase changed to %s; expected %s"
           (phase_to_string actual)
           (phase_to_string Awaiting_initialize))
  | Needs_initialized _ | Session_ready _ ->
    error
      stage
      (Printf.sprintf
         "MCP session phase is %s; expected %s"
         (phase_to_string (phase_of_lifecycle current))
         (phase_to_string Awaiting_initialize))
;;

let transition_initialized session ~stage =
  let current = Atomic.get session.lifecycle in
  match current with
  | Needs_initialized protocol_version ->
    if Atomic.compare_and_set
         session.lifecycle
         current
         (Session_ready protocol_version)
    then Ok ()
    else
      let actual = Atomic.get session.lifecycle |> phase_of_lifecycle in
      error
        stage
        (Printf.sprintf
           "MCP session phase changed to %s; expected %s"
           (phase_to_string actual)
           (phase_to_string Awaiting_initialized))
  | Needs_initialize | Session_ready _ ->
    error
      stage
      (Printf.sprintf
         "MCP session phase is %s; expected %s"
         (phase_to_string (phase_of_lifecycle current))
         (phase_to_string Awaiting_initialized))
;;

let rec validate_message_value ~stage ~path = function
  | `Assoc fields ->
    let seen = Hashtbl.create (min 32 (List.length fields)) in
    let rec loop = function
      | [] -> Ok ()
      | (name, value) :: rest ->
        if Hashtbl.mem seen name
        then error stage (Printf.sprintf "duplicate object key %S at %s" name path)
        else (
          Hashtbl.add seen name ();
          let* () =
            validate_message_value ~stage ~path:(path ^ "." ^ name) value
          in
          loop rest)
    in
    loop fields
  | `List values ->
    let rec loop index = function
      | [] -> Ok ()
      | value :: rest ->
        let* () =
          validate_message_value
            ~stage
            ~path:(Printf.sprintf "%s[%d]" path index)
            value
        in
        loop (index + 1) rest
    in
    loop 0 values
  | `Float value when not (Float.is_finite value) ->
    error stage (Printf.sprintf "non-finite number at %s" path)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> Ok ()
;;

let reject_unknown_fields ~stage ~allowed fields =
  match List.find_opt (fun (name, _) -> not (List.mem name allowed)) fields with
  | None -> Ok ()
  | Some (name, _) -> error stage (Printf.sprintf "unknown field %S" name)
;;

let assoc_at stage = function
  | `Assoc fields -> Ok fields
  | _ -> error stage "expected an object"
;;

let required_string stage name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _ -> error stage (Printf.sprintf "field %S must be a string" name)
  | None -> error stage (Printf.sprintf "missing field %S" name)
;;

let request_id stage = function
  | id ->
    (match Mcp_transport_protocol.request_id_of_yojson id with
     | Error request_id_error ->
       error
         stage
         (Mcp_transport_protocol.request_id_error_to_string request_id_error)
     | Ok request_id ->
       let json = Mcp_transport_protocol.request_id_to_yojson request_id in
       let* call_id =
         match json with
         | `String value | `Intlit value -> Ok value
         | _ -> error stage "typed request id projected to an invalid JSON value"
       in
       Ok (request_id, json, call_id))
;;

let request_id_opt stage fields =
  match List.assoc_opt "id" fields with
  | None -> Ok None
  | Some id ->
    let* request_id, _json, _call_id = request_id stage id in
    Ok (Some request_id)
;;

let params_object stage fields =
  match List.assoc_opt "params" fields with
  | None -> Ok (`Assoc [])
  | Some (`Assoc _ as params) -> Ok params
  | Some _ -> error stage "field \"params\" must be an object"
;;

let protocol_version params =
  let stage = "MCP initialize" in
  let* () =
    Mcp_transport_protocol.validate_initialize_params (Some params)
    |> Result.map_error (fun detail -> { stage; detail })
  in
  match Mcp_transport_protocol.get_field "protocolVersion" params with
  | Some (`String requested) ->
    Mcp_transport_protocol.validate_protocol_version requested
    |> Result.map_error (fun detail -> { stage; detail })
  | None | Some _ -> error stage "invalid protocolVersion"
;;

let initialize ~server_name ~id ~params =
  let* protocol_version = protocol_version params in
  Ok
    ( protocol_version
    , Mcp_transport_protocol.make_response
        ~id
        (`Assoc
           [ "protocolVersion", `String protocol_version
           ; "capabilities", `Assoc [ "tools", `Assoc [] ]
           ; ( "serverInfo"
             , `Assoc
                 [ "name", `String server_name
                 ; "version", `String Runtime_build_version.current
                 ] )
           ]) )
;;

let tool_result_json ~id (result : tool_result) =
  Mcp_transport_protocol.make_response
    ~id
    (`Assoc
       ([ ( "content"
          , `List
              [ `Assoc
                  [ "type", `String "text"
                  ; "text", `String result.content
                  ] ] )
        ]
        @ if result.success then [] else [ "isError", `Bool true ]))
;;

let tools_call ~id ~params ~call_tool =
  let stage = "MCP tools/call" in
  let* _request_id, id, call_id = request_id stage id in
  let* fields = assoc_at stage params in
  let* name = required_string stage "name" fields in
  let* arguments =
    match List.assoc_opt "arguments" fields with
    | None -> Ok (`Assoc [])
    | Some (`Assoc _ as arguments) -> Ok arguments
    | Some _ -> error stage "field \"arguments\" must be an object"
  in
  match call_tool ~name ~call_id ~arguments with
  | None ->
    Ok
      { response =
          Some
            (Mcp_transport_protocol.make_error
               ~id
               (-32602)
               (Printf.sprintf "unknown official-client tool %S" name))
      ; tool_called = false
      }
  | Some result ->
    Ok { response = Some (tool_result_json ~id result); tool_called = true }
;;

(* TEL-OK: pure fail-closed protocol decoder; the runtime caller owns terminal
   error telemetry and control-response delivery. *)
let decode_message message =
  let stage = "MCP message" in
  let* () = validate_message_value ~stage ~path:"$" message in
  let* fields = assoc_at stage message in
  let* () =
    reject_unknown_fields
      ~stage
      ~allowed:[ "jsonrpc"; "id"; "method"; "params" ]
      fields
  in
  let* jsonrpc = required_string stage "jsonrpc" fields in
  if jsonrpc <> "2.0"
  then error stage (Printf.sprintf "unsupported jsonrpc %S" jsonrpc)
  else
    let* method_name = required_string stage "method" fields in
    let* params = params_object stage fields in
    let* request_id = request_id_opt stage fields in
    Ok { method_name; request_id; params }
;;

let dispatch_message ~session ~server_name ~tool_specs ~call_tool message =
  match message.method_name, message.request_id with
    | "initialize", Some request_id ->
      let* () = require_phase session ~stage:"MCP initialize" Awaiting_initialize in
      let id = Mcp_transport_protocol.request_id_to_yojson request_id in
      let* protocol_version, initialize_response =
        initialize ~server_name ~id ~params:message.params
      in
      let* () =
        transition_initialize session ~stage:"MCP initialize" protocol_version
      in
      Ok
        { response = Some initialize_response
        ; tool_called = false
        }
    | "tools/list", Some request_id ->
      let* () = require_phase session ~stage:"MCP tools/list" Ready in
      let id = Mcp_transport_protocol.request_id_to_yojson request_id in
      Ok
        { response =
            Some
              (Mcp_transport_protocol.make_response
                 ~id
                 (`Assoc [ "tools", `List (tool_specs ()) ]))
        ; tool_called = false
        }
    | "tools/call", Some request_id ->
      let* () = require_phase session ~stage:"MCP tools/call" Ready in
      tools_call
        ~id:(Mcp_transport_protocol.request_id_to_yojson request_id)
        ~params:message.params
        ~call_tool
    | "notifications/initialized", None ->
      let* () = transition_initialized session ~stage:"MCP notifications/initialized" in
      Ok { response = None; tool_called = false }
    | _, None ->
      error
        "MCP message"
        (Printf.sprintf "MCP notification %S is not supported" message.method_name)
    | _, Some request_id ->
      let id = Mcp_transport_protocol.request_id_to_yojson request_id in
      Ok
        { response =
            Some
              (Mcp_transport_protocol.make_error
                 ~id
                 (-32601)
                 (Printf.sprintf "MCP method %S is not supported" message.method_name))
        ; tool_called = false
        }
;;

let handle_message ~session ~server_name ~tool_specs ~call_tool message_json =
  let* message = decode_message message_json in
  dispatch_message ~session ~server_name ~tool_specs ~call_tool message
;;
