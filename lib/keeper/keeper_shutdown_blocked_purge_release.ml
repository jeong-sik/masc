let command_schema = "masc.keeper_shutdown.blocked_purge_release.command.v1"
let result_schema = "masc.keeper_shutdown.blocked_purge_release.result.v1"

type command =
  { keeper_id : string
  ; operation_id : Keeper_shutdown_types.Operation_id.t
  ; expected_revision : int
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

type error =
  | Store_release_failed of Keeper_shutdown_store.error
  | Successor_lookup_failed of Keeper_shutdown_store.error
  | Admission_reserved_by_other of Keeper_shutdown_types.Operation_id.t
  | Admission_release_failed of string

type released =
  { operation : Keeper_shutdown_types.t
  ; already_released : bool
  }

let input_error_to_string = function
  | Object_required observed_kind ->
    Printf.sprintf "blocked purge release command must be an object (received %s)" observed_kind
  | Duplicate_fields fields ->
    Printf.sprintf "blocked purge release command contains duplicate field(s): %s" (String.concat ", " fields)
  | Unsupported_fields fields ->
    Printf.sprintf "blocked purge release command contains unsupported field(s): %s" (String.concat ", " fields)
  | Missing_fields fields ->
    Printf.sprintf "blocked purge release command is missing required field(s): %s" (String.concat ", " fields)
  | Invalid_field { field; expectation } -> Printf.sprintf "%s %s" field expectation
  | Unsupported_schema schema -> Printf.sprintf "unsupported blocked purge release schema %S" schema
;;

let input_error_to_json error =
  let kind, details =
    match error with
    | Object_required observed_kind ->
      "object_required", [ "observed_kind", `String observed_kind ]
    | Duplicate_fields fields ->
      "duplicate_fields", [ "fields", `List (List.map (fun field -> `String field) fields) ]
    | Unsupported_fields fields ->
      "unsupported_fields", [ "fields", `List (List.map (fun field -> `String field) fields) ]
    | Missing_fields fields ->
      "missing_fields", [ "fields", `List (List.map (fun field -> `String field) fields) ]
    | Invalid_field { field; expectation } ->
      "invalid_field", [ "field", `String field; "expectation", `String expectation ]
    | Unsupported_schema schema ->
      "unsupported_schema", [ "schema", `String schema ]
  in
  `Assoc
    ([ "error", `String "blocked_purge_release_invalid_input"
     ; "kind", `String kind
     ; "message", `String (input_error_to_string error)
     ]
     @ details)
;;

let expected_fields =
  [ "schema"; "keeper_id"; "operation_id"; "expected_revision"; "reason" ]
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

let exact_nonblank_string ?(max_length = max_int) ~field = function
  | `String value
    when not (String.equal value "")
         && String.equal value (String.trim value)
         && String.length value <= max_length ->
    Ok value
  | `String _ ->
    Error
      (Invalid_field
         { field
         ; expectation =
             Printf.sprintf
               "must be non-empty without surrounding whitespace and at most %d bytes"
               max_length
         })
  | value ->
    Error
      (Invalid_field
         { field
         ; expectation =
             Printf.sprintf "must be a string (received %s)" (Json_util.kind_name value)
         })
;;

let positive_int ~field = function
  | `Int value when value > 0 -> Ok value
  | `Int _ -> Error (Invalid_field { field; expectation = "must be a positive integer" })
  | value ->
    Error
      (Invalid_field
         { field
         ; expectation =
             Printf.sprintf "must be an integer (received %s)" (Json_util.kind_name value)
         })
;;

let parse_command = function
  | `Assoc fields ->
    let open Result.Syntax in
    let* () = validate_exact_fields fields in
    let* schema_json = required "schema" fields in
    let* schema = exact_nonblank_string ~field:"schema" schema_json in
    let* () =
      if String.equal schema command_schema
      then Ok ()
      else Error (Unsupported_schema schema)
    in
    let* keeper_id_json = required "keeper_id" fields in
    let* keeper_id = exact_nonblank_string ~field:"keeper_id" keeper_id_json in
    let* () =
      if Keeper_config.validate_name keeper_id
      then Ok ()
      else
        Error
          (Invalid_field
             { field = "keeper_id"; expectation = "must be a valid Keeper id" })
    in
    let* operation_id_json = required "operation_id" fields in
    let* operation_id_string =
      exact_nonblank_string ~field:"operation_id" operation_id_json
    in
    let* operation_id =
      Keeper_shutdown_types.Operation_id.of_string operation_id_string
      |> Result.map_error (fun _ ->
        Invalid_field
          { field = "operation_id"
          ; expectation = "must be a valid Keeper shutdown operation id"
          })
    in
    let* expected_revision_json = required "expected_revision" fields in
    let* expected_revision =
      positive_int ~field:"expected_revision" expected_revision_json
    in
    let* reason_json = required "reason" fields in
    let* reason = exact_nonblank_string ~max_length:1024 ~field:"reason" reason_json in
    Ok { keeper_id; operation_id; expected_revision; reason }
  | value -> Error (Object_required (Json_util.kind_name value))
;;

let error_to_string = function
  | Store_release_failed error -> Keeper_shutdown_store.error_to_string error
  | Successor_lookup_failed error ->
    "blocked purge was released, but successor admission lookup failed: "
    ^ Keeper_shutdown_store.error_to_string error
  | Admission_reserved_by_other operation_id ->
    Printf.sprintf
      "blocked purge was released, but admission belongs to operation %s"
      (Keeper_shutdown_types.Operation_id.to_string operation_id)
  | Admission_release_failed detail ->
    "blocked purge was released, but its admission fence could not be released: " ^ detail
;;

let release_admission ~config operation =
  let open Result.Syntax in
  let* successor_operation_id =
    Keeper_shutdown_store.corrupt_operation_id_for_keeper
      ~config
      ~keeper_name:operation.Keeper_shutdown_types.keeper_name
    |> Result.map_error (fun error -> Successor_lookup_failed error)
  in
  let transition () =
    Keeper_owner_registry.transition_shutdown
      ~base_path:config.Workspace.base_path
      ~keeper_name:operation.keeper_name
      ~from_operation_id:operation.operation_id
      ~to_operation_id:successor_operation_id
  in
  match transition () with
  | Ok Keeper_owner.Shutdown_transition_applied
  | Ok Keeper_owner.Shutdown_transition_already_applied -> Ok ()
  | Ok (Keeper_owner.Shutdown_transition_reserved_by_other existing) ->
    Error (Admission_reserved_by_other existing)
  | Error error ->
    if Keeper_shutdown_finalize.admission_already_released_by_removal ~config operation error
    then
      (match
         Keeper_shutdown_intake_fence.transition_shutdown
           ~base_path:config.Workspace.base_path
           ~keeper_name:operation.keeper_name
           ~from_operation_id:operation.operation_id
           ~to_operation_id:successor_operation_id
       with
       | Keeper_shutdown_intake_fence.Transition_applied
       | Keeper_shutdown_intake_fence.Transition_already_applied -> Ok ()
       | Keeper_shutdown_intake_fence.Transition_reserved_by_other existing ->
         Error (Admission_reserved_by_other existing))
    else Error (Admission_release_failed (Keeper_owner_registry.command_error_to_string error))
;;

let execute ~config ~actor command =
  let open Result.Syntax in
  let* release =
    Keeper_shutdown_store.release_blocked_dashboard_purge
      ~config
      ~keeper_name:command.keeper_id
      ~operation_id:command.operation_id
      ~expected_revision:command.expected_revision
      ~actor
      ~reason:command.reason
      ~now:Masc_domain.now_iso
    |> Result.map_error (fun error -> Store_release_failed error)
  in
  let operation, already_released =
    match release with
    | Keeper_shutdown_store.Superseded_persisted operation -> operation, false
    | Keeper_shutdown_store.Superseded_already_persisted operation -> operation, true
  in
  let* () = release_admission ~config operation in
  Ok { operation; already_released }
;;

let audit config ~actor command ~outcome =
  try
    Audit_log.log_action
      config
      ~agent_id:actor
      ~action:(Audit_log.Custom "keeper_blocked_purge_release")
      ~details:
        (`Assoc
          [ "keeper_id", `String command.keeper_id
          ; ( "operation_id"
            , `String
                (Keeper_shutdown_types.Operation_id.to_string command.operation_id) )
          ; "expected_revision", `Int command.expected_revision
          ; "reason", `String command.reason
          ])
      ~outcome
      ();
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

let success_json ~audit command released =
  `Assoc
    [ "schema", `String result_schema
    ; "ok", `Bool true
    ; "keeper_id", `String command.keeper_id
    ; ( "operation_id"
      , `String (Keeper_shutdown_types.Operation_id.to_string command.operation_id) )
    ; "expected_revision", `Int command.expected_revision
    ; "revision", `Int released.operation.Keeper_shutdown_types.revision
    ; "already_released", `Bool released.already_released
    ; "admission_released", `Bool true
    ; ( "next_action"
      , `String "materialize_keeper_paused_then_reissue_exact_purge" )
    ; "audit", audit
    ]
;;

let error_json ~audit error =
  `Assoc
    [ "error", `String "blocked_purge_release_failed"
    ; "message", `String (error_to_string error)
    ; "audit", audit
    ]
;;
