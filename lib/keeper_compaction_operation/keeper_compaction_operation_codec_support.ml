module Operation = Keeper_compaction_operation

type field_error =
  | Unknown_field of
      { path : string
      ; field : string
      }
  | Duplicate_field of
      { path : string
      ; field : string
      }
  | Missing_field of
      { path : string
      ; field : string
      }
  | Wrong_type of
      { path : string
      ; field : string
      ; expected : string
      }

type decode_error =
  | Expected_object of string
  | Invalid_field of field_error
  | Unknown_event_kind of string
  | Unknown_failure_kind of string
  | Unknown_reconciliation_reason of string
  | Invalid_operation_id of Keeper_compaction_operation_identity.id_error
  | Invalid_attempt_id of Keeper_compaction_operation_identity.id_error
  | Invalid_keeper_name of string
  | Invalid_trace_id of string
  | Invalid_cause of Keeper_compaction_operation_identity.Cause.error
  | Invalid_checkpoint of Keeper_checkpoint_ref.create_error
  | Invalid_trigger of Compaction_trigger.decode_error
  | Invalid_producer of Tool_invocation_ref.decode_error
  | Invalid_evidence of Keeper_compaction_evidence.decode_error
  | Invalid_turn_ref of string

let ( let* ) = Result.bind
let field_error error = Error (Invalid_field error)

let exact_object ~path ~allowed ~required = function
  | `Assoc fields ->
    let rec validate seen = function
      | [] -> Ok ()
      | (field, _) :: _ when List.mem field seen ->
        field_error (Duplicate_field { path; field })
      | (field, _) :: _ when not (List.mem field allowed) ->
        field_error (Unknown_field { path; field })
      | (field, _) :: rest -> validate (field :: seen) rest
    in
    let rec require = function
      | [] -> Ok fields
      | field :: rest ->
        if List.mem_assoc field fields
        then require rest
        else field_error (Missing_field { path; field })
    in
    let* () = validate [] fields in
    require required
  | _ -> Error (Expected_object path)
;;

let required_field ~path field fields =
  match List.assoc_opt field fields with
  | Some value -> Ok value
  | None -> field_error (Missing_field { path; field })
;;

let string_field ~path field = function
  | `String value -> Ok value
  | _ -> field_error (Wrong_type { path; field; expected = "string" })
;;

let int_field ~path field = function
  | `Int value -> Ok value
  | _ -> field_error (Wrong_type { path; field; expected = "integer" })
;;

let operation_id ~path field json =
  let* value = string_field ~path field json in
  Operation.Operation_id.of_string value
  |> Result.map_error (fun error -> Invalid_operation_id error)
;;

let attempt_id ~path field json =
  let* value = string_field ~path field json in
  Operation.Attempt_id.of_string value
  |> Result.map_error (fun error -> Invalid_attempt_id error)
;;

let keeper_name ~path field json =
  let* value = string_field ~path field json in
  Keeper_id.Keeper_name.of_string value
  |> Result.map_error (fun error -> Invalid_keeper_name error)
;;

let cause ~path field json =
  let* value = string_field ~path field json in
  Operation.Cause.of_string value
  |> Result.map_error (fun error -> Invalid_cause error)
;;

let checkpoint ~path json =
  let fields = [ "trace_id"; "generation"; "turn_count"; "sha256" ] in
  let* values = exact_object ~path ~allowed:fields ~required:fields json in
  let* trace_json = required_field ~path "trace_id" values in
  let* trace_value = string_field ~path "trace_id" trace_json in
  let* trace_id =
    Keeper_id.Trace_id.of_string trace_value
    |> Result.map_error (fun error -> Invalid_trace_id error)
  in
  let* generation_json = required_field ~path "generation" values in
  let* generation = int_field ~path "generation" generation_json in
  let* turn_count_json = required_field ~path "turn_count" values in
  let* turn_count = int_field ~path "turn_count" turn_count_json in
  let* sha_json = required_field ~path "sha256" values in
  let* sha256 = string_field ~path "sha256" sha_json in
  Keeper_checkpoint_ref.of_persisted ~trace_id ~generation ~turn_count ~sha256
  |> Result.map_error (fun error -> Invalid_checkpoint error)
;;

let evidence ~path json =
  let fields = [ "selected_runtime_id"; "counts" ] in
  let* values = exact_object ~path ~allowed:fields ~required:fields json in
  let* runtime_json = required_field ~path "selected_runtime_id" values in
  let* selected_runtime_id =
    match runtime_json with
    | `Null -> Ok None
    | `String value -> Ok (Some value)
    | _ ->
      field_error
        (Wrong_type
           { path; field = "selected_runtime_id"; expected = "string or null" })
  in
  let* counts = required_field ~path "counts" values in
  Keeper_compaction_evidence.of_json ~selected_runtime_id counts
  |> Result.map_error (fun error -> Invalid_evidence error)
;;

let trigger ~path json =
  let* trigger =
    Compaction_trigger.of_detail_json json
    |> Result.map_error (fun error -> Invalid_trigger error)
  in
  let allowed, required =
    match trigger with
    | Compaction_trigger.Manual -> [ "kind" ], [ "kind" ]
    | Provider_overflow _ ->
      [ "kind"; "limit_tokens" ], [ "kind"; "limit_tokens" ]
  in
  let* _ = exact_object ~path ~allowed ~required json in
  Ok trigger
;;

let producer_invocation = function
  | `Null -> Ok None
  | json ->
    Tool_invocation_ref.of_yojson json
    |> Result.map_error (fun error -> Invalid_producer error)
    |> Result.map Option.some
;;

let turn_ref json =
  Ids.Turn_ref.of_yojson json
  |> Result.map_error (fun error -> Invalid_turn_ref error)
;;
