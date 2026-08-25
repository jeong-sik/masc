module Http = Http_server_eio
module Operation = Keeper_owner.Chat_operation
module Operation_id = Operation.Operation_id
module Owner = Keeper_owner
module Registry = Keeper_owner_registry

let read_permission = Masc_domain.CanReadState
let mutation_permission = Masc_domain.CanBroadcast

type get_route =
  | Operation_list of { keeper_name : string }
  | Operation_exact of
      { keeper_name : string
      ; raw_operation_id : string
      }

type mutation =
  | Edit
  | Move_to_end
  | Cancel

type mutation_route =
  { keeper_name : string
  ; raw_operation_id : string
  ; mutation : mutation
  }

type api_error =
  { status : Httpun.Status.t
  ; code : string
  ; message : string
  }

let path_segments path =
  path
  |> String.split_on_char '/'
  |> List.filter_map (fun value ->
    let value = Uri.pct_decode value |> String.trim in
    if String.equal value "" then None else Some value)
;;

let get_route path =
  match path_segments path with
  | [ "api"; "v1"; "keepers"; keeper_name; "chat"; "operations" ] ->
    Some (Operation_list { keeper_name })
  | [ "api"; "v1"; "keepers"; keeper_name; "chat"; "operations"; raw_operation_id ] ->
    Some (Operation_exact { keeper_name; raw_operation_id })
  | _ -> None
;;

let mutation_route path =
  match path_segments path with
  | [ "api"; "v1"; "keepers"; keeper_name; "chat"; "operations"
    ; raw_operation_id; action
    ] ->
    let mutation =
      match action with
      | "edit" -> Some Edit
      | "move-to-end" -> Some Move_to_end
      | "cancel" -> Some Cancel
      | _ -> None
    in
    Option.map
      (fun mutation -> { keeper_name; raw_operation_id; mutation })
      mutation
  | _ -> None
;;

let error_json error =
  `Assoc
    [ "schema", `String "masc.keeper_chat_operation.error.v1"
    ; "error", `String error.code
    ; "message", `String error.message
    ]
;;

let respond_error request reqd error =
  Log.Dashboard.warn "keeper_chat_operation_api error=%s" error.code;
  Server_auth.respond_json_value_with_cors
    ~status:error.status
    request
    reqd
    (error_json error)
;;

let invalid_input message = { status = `Bad_request; code = "invalid_input"; message }
let unknown_operation message = { status = `Not_found; code = "unknown_operation"; message }

let conflict code message =
  { status = `Conflict; code; message }
;;

let unavailable code message =
  { status = `Service_unavailable; code; message }
;;

let api_error_of_command_error error =
  let message = Registry.command_error_to_string error in
  match error with
  | Registry.Command_lookup_failed
      (Owner_not_found _ | Owner_unavailable _ | Inventory_not_installed _) ->
    unknown_operation message
  | Command_lookup_failed (Owner_initialization_failed _ | Inventory_stopping) ->
    unavailable "store_unavailable" message
  | Command_lifecycle_reserved _ -> unavailable "owner_stopping" message
  | Command_rejected (Owner.Operation_rejected operation_error) ->
    (match Owner.operation_error_kind operation_error with
     | Invalid_operation_input -> invalid_input message
     | Unknown_operation -> unknown_operation message
     | Operation_not_queued -> conflict "not_queued" message
     | Operation_idempotency_conflict -> conflict "idempotency_conflict" message
     | Operation_store_unavailable ->
       unavailable "store_unavailable" message)
  | Command_rejected (Owner.Store_unavailable _) ->
    unavailable "store_unavailable" message
  | Command_rejected (Owner.Owner_stopping | Owner.Owner_closed) ->
    unavailable "owner_stopping" message
  | Command_rejected (Owner.Reducer_rejected _) ->
    unavailable "store_unavailable" message
;;

let operation_id raw =
  Operation_id.of_string raw |> Result.map_error invalid_input
;;

let base_path state =
  (Mcp_server.workspace_config state).Workspace.base_path
;;

let parse_after_sequence request =
  match Server_utils.query_param request "after_sequence" with
  | None -> Ok None
  | Some raw ->
    (match Int64.of_string_opt (String.trim raw) with
     | Some value when Int64.compare value 0L >= 0 -> Ok (Some value)
     | Some _ | None -> Error (invalid_input "after_sequence must be a non-negative int64"))
;;

let handle_get state request reqd = function
  | Operation_exact { keeper_name; raw_operation_id } ->
    (match operation_id raw_operation_id with
     | Error error -> respond_error request reqd error
     | Ok operation_id ->
       (match Registry.exact_operation ~base_path:(base_path state) ~keeper_name operation_id with
        | Error error -> respond_error request reqd (api_error_of_command_error error)
        | Ok None ->
          respond_error
            request
            reqd
            (unknown_operation
               ("unknown Keeper chat operation: " ^ Operation_id.to_string operation_id))
        | Ok (Some operation) ->
          Log.Dashboard.debug
            "keeper_chat_operation_get keeper=%s operation_id=%s state=%s"
            keeper_name
            (Operation_id.to_string operation.operation_id)
            (Operation.state_to_string operation.state);
          Server_auth.respond_json_value_with_cors
            request
            reqd
            (Operation.to_json operation)))
  | Operation_list { keeper_name } ->
    let state_filter = Server_utils.query_param request "state" in
    (match parse_after_sequence request with
     | Error error -> respond_error request reqd error
     | Ok after_sequence ->
       (match state_filter with
        | Some "queued" ->
       (match
          Registry.list_queued_operations
            ~base_path:(base_path state)
            ~keeper_name
            ~after_sequence
            ~limit:100
        with
        | Error error -> respond_error request reqd (api_error_of_command_error error)
        | Ok operations ->
          Log.Dashboard.debug
            "keeper_chat_operation_list keeper=%s state=queued count=%d"
            keeper_name
            (List.length operations);
          Server_auth.respond_json_value_with_cors
            request
            reqd
            (`Assoc
               [ "schema", `String "masc.keeper_chat_operations.list.v1"
               ; "state", `String "Queued"
               ; "operations", `List (List.map Operation.to_json operations)
               ]))
        | Some _ | None ->
          respond_error request reqd (invalid_input "state=queued is required")))
;;

let strict_object body =
  try
    match Yojson.Safe.from_string body with
    | `Assoc fields ->
      let names = List.map fst fields in
      if List.length names <> List.length (List.sort_uniq String.compare names)
      then Error (invalid_input "request body must contain unique fields")
      else Ok fields
    | _ -> Error (invalid_input "request body must be a JSON object")
  with
  | Yojson.Json_error detail -> Error (invalid_input ("invalid json: " ^ detail))
;;

let parse_edit body =
  match strict_object body with
  | Error _ as error -> error
  | Ok [ "input", input ] ->
    (match Keeper_chat_operation_payload.input_of_json input with
     | Ok _ -> Ok input
     | Error detail -> Error (invalid_input ("input: " ^ detail)))
  | Ok _ -> Error (invalid_input "edit body must contain exactly the input field")
;;

let parse_empty mutation body =
  match strict_object body with
  | Ok [] -> Ok ()
  | Ok _ -> Error (invalid_input (mutation ^ " body must be an empty object"))
  | Error _ as error -> error
;;

let mutation_to_string = function
  | Edit -> "edit"
  | Move_to_end -> "move_to_end"
  | Cancel -> "cancel"
;;

let handle_mutation state request reqd route body =
  match operation_id route.raw_operation_id with
  | Error error -> respond_error request reqd error
  | Ok operation_id ->
    let result =
      match route.mutation with
      | Edit ->
        (match parse_edit body with
         | Error error -> Error error
         | Ok input ->
           Registry.edit_queued_operation
             ~base_path:(base_path state)
             ~keeper_name:route.keeper_name
             ~operation_id
             ~input
           |> Result.map_error api_error_of_command_error)
      | Move_to_end ->
        (match parse_empty "move-to-end" body with
         | Error error -> Error error
         | Ok () ->
           Registry.move_queued_operation_to_end
             ~base_path:(base_path state)
             ~keeper_name:route.keeper_name
             operation_id
           |> Result.map_error api_error_of_command_error)
      | Cancel ->
        (match parse_empty "cancel" body with
         | Error error -> Error error
         | Ok () ->
           Registry.cancel_queued_operation
             ~base_path:(base_path state)
             ~keeper_name:route.keeper_name
             operation_id
           |> Result.map_error api_error_of_command_error)
    in
    (match result with
     | Error error -> respond_error request reqd error
     | Ok operation ->
       Log.Dashboard.info
         "keeper_chat_operation_mutation keeper=%s operation_id=%s action=%s state=%s"
         route.keeper_name
         (Operation_id.to_string operation.operation_id)
         (mutation_to_string route.mutation)
         (Operation.state_to_string operation.state);
       Server_auth.respond_json_value_with_cors
         request
         reqd
       (Operation.to_json operation))
;;

module For_testing = struct
  let parse_mutation_body mutation body =
    match mutation with
    | Edit ->
      parse_edit body
      |> Result.map Option.some
      |> Result.map_error (fun error -> error.code)
    | Move_to_end ->
      parse_empty "move-to-end" body
      |> Result.map (fun () -> None)
      |> Result.map_error (fun error -> error.code)
    | Cancel ->
      parse_empty "cancel" body
      |> Result.map (fun () -> None)
      |> Result.map_error (fun error -> error.code)
  ;;
end
