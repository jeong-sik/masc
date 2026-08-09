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

let ( let* ) = Result.bind
let error stage detail = Error { stage; detail }

let rec validate_unique_object_keys ~stage ~path = function
  | `Assoc fields ->
    let seen = Hashtbl.create (min 64 (List.length fields)) in
    let rec loop = function
      | [] -> Ok ()
      | (name, value) :: rest ->
        if Hashtbl.mem seen name
        then error stage (Printf.sprintf "duplicate object key %S at %s" name path)
        else
          let () = Hashtbl.add seen name () in
          let* () =
            validate_unique_object_keys ~stage ~path:(path ^ "." ^ name) value
          in
          loop rest
    in
    loop fields
  | `List values ->
    let rec loop index = function
      | [] -> Ok ()
      | value :: rest ->
        let* () =
          validate_unique_object_keys
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

let parse_message text =
  let stage = "MCP message" in
  let* message =
    try Ok (Yojson.Safe.from_string text) with
    | Yojson.Json_error detail -> error stage ("invalid JSON: " ^ detail)
    | Stack_overflow -> error stage "JSON nesting exceeds parser limits"
    | Failure detail -> error stage ("invalid JSON: " ^ detail)
  in
  let* () = validate_unique_object_keys ~stage ~path:"$" message in
  Ok message
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

let response ~id result =
  `Assoc [ "jsonrpc", `String "2.0"; "id", id; "result", result ]
;;

let error_response ~id ~code message =
  `Assoc
    [ "jsonrpc", `String "2.0"
    ; "id", id
    ; "error", `Assoc [ "code", `Int code; "message", `String message ]
    ]
;;

let request_id stage = function
  | `String id when String.trim id <> "" -> Ok (`String id, id)
  | `Int id -> Ok (`Int id, string_of_int id)
  | _ -> error stage "request id must be a non-empty string or integer"
;;

let protocol_version params =
  let supported = [ "2025-11-25"; "2025-06-18"; "2025-03-26"; "2024-11-05" ] in
  match params with
  | `Assoc fields ->
    (match List.assoc_opt "protocolVersion" fields with
     | Some (`String requested) when List.mem requested supported -> Ok requested
     | Some (`String _) -> Ok "2025-11-25"
     | None -> Ok "2024-11-05"
     | Some _ -> error "MCP initialize" "field \"protocolVersion\" must be a string")
  | _ -> error "MCP initialize" "params must be an object"
;;

let initialize ~server_name ~id ~params =
  let* protocol_version = protocol_version params in
  Ok
    (response
       ~id
       (`Assoc
          [ "protocolVersion", `String protocol_version
          ; "capabilities", `Assoc [ "tools", `Assoc [] ]
          ; ( "serverInfo"
            , `Assoc
                [ "name", `String server_name
                ; "version", `String "1.0.0"
                ] )
          ]))
;;

let tool_result_json ~id (result : tool_result) =
  response
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
  let* id, call_id = request_id stage id in
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
            (error_response
               ~id
               ~code:(-32602)
               (Printf.sprintf "unknown official-client tool %S" name))
      ; tool_called = false
      }
  | Some result ->
    Ok { response = Some (tool_result_json ~id result); tool_called = true }
;;

let handle_message ~server_name ~tool_specs ~call_tool message =
  let stage = "MCP message" in
  let* fields = assoc_at stage message in
  let* jsonrpc = required_string stage "jsonrpc" fields in
  if jsonrpc <> "2.0"
  then error stage (Printf.sprintf "unsupported jsonrpc %S" jsonrpc)
  else
    let* method_ = required_string stage "method" fields in
    let id = Option.value (List.assoc_opt "id" fields) ~default:`Null in
    let params = Option.value (List.assoc_opt "params" fields) ~default:(`Assoc []) in
    let* request =
      if id = `Null
      then Ok None
      else
        let* id, _call_id = request_id stage id in
        Ok (Some id)
    in
    match method_, request with
    | "initialize", Some id ->
      let* initialize_response = initialize ~server_name ~id ~params in
      Ok
        { response = Some initialize_response
        ; tool_called = false
        }
    | "tools/list", Some id ->
      Ok
        { response =
            Some (response ~id (`Assoc [ "tools", `List (tool_specs ()) ]))
        ; tool_called = false
        }
    | "tools/call", Some id -> tools_call ~id ~params ~call_tool
    | "notifications/initialized", None ->
      Ok { response = None; tool_called = false }
    | _, None ->
      error
        stage
        (Printf.sprintf "MCP notification %S is not supported" method_)
    | _, Some id ->
      Ok
        { response =
            Some
              (error_response
                 ~id
                 ~code:(-32601)
                 (Printf.sprintf "MCP method %S is not supported" method_))
        ; tool_called = false
        }
;;

let handle_wire_message ~server_name ~tool_specs ~call_tool text =
  let* message = parse_message text in
  handle_message ~server_name ~tool_specs ~call_tool message
;;
