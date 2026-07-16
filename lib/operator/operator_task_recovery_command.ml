let tool_command_schema = "workspace.task.operator_recovery.command.v1"
let result_schema = "workspace.task.operator_recovery.result.v1"

type t =
  { task_id : string
  ; expected_assignee : string
  ; expected_version : int
  ; reason : string
  }

type input_error =
  | Object_required of string
  | Duplicate_fields of string list
  | Unsupported_fields of string list
  | Missing_fields of string list
  | Invalid_field of
      { field : string
      ; expectation : string
      }
  | Unsupported_schema of string

let input_error_to_string = function
  | Object_required observed_kind ->
    Printf.sprintf "operator task recovery command must be an object (received %s)" observed_kind
  | Duplicate_fields fields ->
    Printf.sprintf
      "operator task recovery command contains duplicate field(s): %s"
      (String.concat ", " fields)
  | Unsupported_fields fields ->
    Printf.sprintf
      "operator task recovery command contains unsupported field(s): %s"
      (String.concat ", " fields)
  | Missing_fields fields ->
    Printf.sprintf
      "operator task recovery command is missing required field(s): %s"
      (String.concat ", " fields)
  | Invalid_field { field; expectation } -> Printf.sprintf "%s %s" field expectation
  | Unsupported_schema schema ->
    Printf.sprintf "unsupported operator task recovery schema %S" schema
;;

let input_error_to_json error =
  let kind, details =
    match error with
    | Object_required observed_kind ->
      "object_required", [ "observed_kind", `String observed_kind ]
    | Duplicate_fields fields ->
      ( "duplicate_fields"
      , [ "fields", `List (List.map (fun field -> `String field) fields) ] )
    | Unsupported_fields fields ->
      ( "unsupported_fields"
      , [ "fields", `List (List.map (fun field -> `String field) fields) ] )
    | Missing_fields fields ->
      ( "missing_fields"
      , [ "fields", `List (List.map (fun field -> `String field) fields) ] )
    | Invalid_field { field; expectation } ->
      "invalid_field", [ "field", `String field; "expectation", `String expectation ]
    | Unsupported_schema schema ->
      "unsupported_schema", [ "schema", `String schema ]
  in
  `Assoc
    ([ "error", `String "operator_task_recovery_invalid_input"
     ; "kind", `String kind
     ; "message", `String (input_error_to_string error)
     ]
     @ details)
;;

let expected_fields =
  [ "schema"; "task_id"; "expected_assignee"; "expected_version"; "reason" ]
;;

let duplicate_fields fields =
  let rec loop seen duplicates = function
    | [] -> List.rev duplicates |> List.sort_uniq String.compare
    | (field, _) :: rest ->
      if List.mem field seen
      then loop seen (field :: duplicates) rest
      else loop (field :: seen) duplicates rest
  in
  loop [] [] fields
;;

let validate_exact_fields fields =
  match duplicate_fields fields with
  | _ :: _ as duplicates -> Error (Duplicate_fields duplicates)
  | [] ->
    let unsupported =
      List.filter_map
        (fun (field, _) -> if List.mem field expected_fields then None else Some field)
        fields
    in
    let missing =
      List.filter (fun field -> not (List.mem_assoc field fields)) expected_fields
    in
    if unsupported <> []
    then Error (Unsupported_fields unsupported)
    else if missing <> []
    then Error (Missing_fields missing)
    else Ok ()
;;

let required field fields =
  match List.assoc_opt field fields with
  | Some value -> Ok value
  | None -> Error (Missing_fields [ field ])
;;

let exact_nonblank_string ~field = function
  | `String value
    when not (String.equal value "") && String.equal value (String.trim value) ->
    Ok value
  | `String _ ->
    Error
      (Invalid_field
         { field; expectation = "must be non-empty without surrounding whitespace" })
  | value ->
    Error
      (Invalid_field
         { field
         ; expectation =
             Printf.sprintf "must be a string (received %s)" (Json_util.kind_name value)
         })
;;

let nonnegative_int ~field = function
  | `Int value when value >= 0 -> Ok value
  | `Int _ ->
    Error (Invalid_field { field; expectation = "must be a non-negative integer" })
  | value ->
    Error
      (Invalid_field
         { field
         ; expectation =
             Printf.sprintf "must be an integer (received %s)" (Json_util.kind_name value)
         })
;;

let parse_tool_command = function
  | `Assoc fields ->
    let open Result.Syntax in
    let* () = validate_exact_fields fields in
    let* schema_json = required "schema" fields in
    let* schema = exact_nonblank_string ~field:"schema" schema_json in
    let* () =
      if String.equal schema tool_command_schema
      then Ok ()
      else Error (Unsupported_schema schema)
    in
    let* task_id_json = required "task_id" fields in
    let* task_id = exact_nonblank_string ~field:"task_id" task_id_json in
    let* expected_assignee_json = required "expected_assignee" fields in
    let* expected_assignee =
      exact_nonblank_string ~field:"expected_assignee" expected_assignee_json
    in
    let* expected_version_json = required "expected_version" fields in
    let* expected_version =
      nonnegative_int ~field:"expected_version" expected_version_json
    in
    let* reason_json = required "reason" fields in
    let* reason = exact_nonblank_string ~field:"reason" reason_json in
    Ok { task_id; expected_assignee; expected_version; reason }
  | value -> Error (Object_required (Json_util.kind_name value))
;;

let execute config ~actor command =
  Workspace.recover_owned_task_to_todo_r
    config
    ~operator_actor:actor
    ~task_id:command.task_id
    ~expected_assignee:command.expected_assignee
    ~expected_version:command.expected_version
    ~reason:command.reason
    ()
;;

let audit config ~actor command ~outcome =
  try
    Audit_log.log_action
      config
      ~agent_id:actor
      ~action:(Audit_log.Custom "operator_task_recovery")
      ~details:
        (`Assoc
          [ "task_id", `String command.task_id
          ; "expected_assignee", `String command.expected_assignee
          ; "expected_version", `Int command.expected_version
          ; "reason", `String command.reason
          ])
      ~outcome
      ();
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

let audit_json = function
  | Ok () -> `Assoc [ "recorded", `Bool true ]
  | Error detail ->
    `Assoc
      [ "recorded", `Bool false
      ; "error", `String (Observability_redact.redact_text detail)
      ]
;;

let success_json ~audit command
    (result : Workspace.operator_task_recovery_result) =
  `Assoc
    [ "schema", `String result_schema
    ; "task_id", `String result.task_id
    ; "expected_assignee", `String command.expected_assignee
    ; "previous_assignee", `String result.previous_assignee
    ; ( "previous_status"
      , `String (Masc_domain.task_status_to_string result.previous_status) )
    ; "status", `String "todo"
    ; "backlog_version", `Int result.backlog_version
    ; "audit", audit
    ]
;;

let mutation_error_json ~audit error =
  `Assoc
    [ "error", `String "operator_task_recovery_failed"
    ; "message", `String (Masc_domain.masc_error_to_string error)
    ; "masc_error", Masc_error.to_yojson error
    ; "audit", audit
    ]
;;
