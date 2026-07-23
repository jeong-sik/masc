let request_schema = "keeper_chat_queue.recovery.request.v1"
let tool_command_schema = "keeper_chat_queue.recovery.command.v1"
let result_schema = "keeper_chat_queue.recovery.result.v1"

type cancellation =
  { detail : string
  ; outcome_ref : string option
  }

type decision =
  | Requeue_unconfirmed
  | Cancel_unconfirmed of cancellation

type request =
  { expected_revision : int64
  ; lease_id : string
  ; decision : decision
  }

type t =
  { keeper_name : string
  ; receipt_id : Keeper_chat_queue.Receipt_id.t
  ; request : request
  }

type input_error =
  | Object_required of
      { context : string
      ; observed_kind : string
      }
  | Duplicate_fields of
      { context : string
      ; fields : string list
      }
  | Unsupported_fields of
      { context : string
      ; fields : string list
      }
  | Missing_fields of
      { context : string
      ; fields : string list
      }
  | Invalid_field of
      { field : string
      ; expectation : string
      }
  | Unsupported_schema of string
  | Unsupported_decision of string
  | Invalid_keeper_name of string
  | Invalid_receipt_id of string

let input_error_to_string = function
  | Object_required { context; observed_kind } ->
    Printf.sprintf "%s must be an object (received %s)" context observed_kind
  | Duplicate_fields { context; fields } ->
    Printf.sprintf "%s contains duplicate field(s): %s" context
      (String.concat ", " fields)
  | Unsupported_fields { context; fields } ->
    Printf.sprintf "%s contains unsupported field(s): %s" context
      (String.concat ", " fields)
  | Missing_fields { context; fields } ->
    Printf.sprintf "%s is missing required field(s): %s" context
      (String.concat ", " fields)
  | Invalid_field { field; expectation } ->
    Printf.sprintf "%s %s" field expectation
  | Unsupported_schema schema ->
    Printf.sprintf "unsupported recovery command schema %S" schema
  | Unsupported_decision kind ->
    Printf.sprintf "unsupported recovery decision kind %S" kind
  | Invalid_keeper_name keeper_name ->
    Printf.sprintf "invalid keeper name %S" keeper_name
  | Invalid_receipt_id detail -> detail
;;
let input_error_to_json error =
  let kind, details =
    match error with
    | Object_required { context; observed_kind } ->
      ( "object_required"
      , [ "context", `String context; "observed_kind", `String observed_kind ] )
    | Duplicate_fields { context; fields } ->
      ( "duplicate_fields"
      , [ "context", `String context
        ; "fields", `List (List.map (fun field -> `String field) fields)
        ] )
    | Unsupported_fields { context; fields } ->
      ( "unsupported_fields"
      , [ "context", `String context
        ; "fields", `List (List.map (fun field -> `String field) fields)
        ] )
    | Missing_fields { context; fields } ->
      ( "missing_fields"
      , [ "context", `String context
        ; "fields", `List (List.map (fun field -> `String field) fields)
        ] )
    | Invalid_field { field; expectation } ->
      ( "invalid_field"
      , [ "field", `String field; "expectation", `String expectation ] )
    | Unsupported_schema schema ->
      "unsupported_schema", [ "schema", `String schema ]
    | Unsupported_decision decision ->
      "unsupported_decision", [ "decision", `String decision ]
    | Invalid_keeper_name keeper_name ->
      "invalid_keeper_name", [ "keeper_name", `String keeper_name ]
    | Invalid_receipt_id detail ->
      "invalid_receipt_id", [ "detail", `String detail ]
  in
  `Assoc
    ([ "error", `String "keeper_chat_recovery_invalid_input"
     ; "kind", `String kind
     ; "message", `String (input_error_to_string error)
     ]
     @ details)
;;

let dedupe_keep_order values =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | value :: rest ->
      if List.mem value seen
      then loop seen acc rest
      else loop (value :: seen) (value :: acc) rest
  in
  loop [] [] values
;;

let duplicate_fields fields =
  let rec loop seen duplicates = function
    | [] -> dedupe_keep_order (List.rev duplicates)
    | (field, _) :: rest ->
      if List.mem field seen
      then loop seen (field :: duplicates) rest
      else loop (field :: seen) duplicates rest
  in
  loop [] [] fields
;;

let validate_exact_object ~context ~expected fields =
  match duplicate_fields fields with
  | _ :: _ as fields -> Error (Duplicate_fields { context; fields })
  | [] ->
    let unsupported =
      List.filter_map
        (fun (field, _) -> if List.mem field expected then None else Some field)
        fields
    in
    let missing =
      List.filter (fun field -> not (List.mem_assoc field fields)) expected
    in
    if unsupported <> []
    then Error (Unsupported_fields { context; fields = unsupported })
    else if missing <> []
    then Error (Missing_fields { context; fields = missing })
    else Ok ()
;;

let required field fields =
  match List.assoc_opt field fields with
  | Some value -> Ok value
  | None -> Error (Missing_fields { context = "recovery command"; fields = [ field ] })
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

let canonical_nonnegative_int64 ~field = function
  | `String wire ->
    (match Int64.of_string_opt wire with
     | Some value
       when Int64.compare value 0L >= 0
            && String.equal wire (Int64.to_string value) ->
       Ok value
     | Some _ | None ->
       Error
         (Invalid_field
            { field; expectation = "must be a canonical non-negative int64 string" }))
  | value ->
    Error
      (Invalid_field
         { field
         ; expectation =
             Printf.sprintf
               "must be a canonical int64 string (received %s)"
               (Json_util.kind_name value)
         })
;;

let parse_decision = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* kind_json = required "kind" fields in
    let* kind = exact_nonblank_string ~field:"decision.kind" kind_json in
    (match kind with
     | "requeue_unconfirmed" ->
       let* () =
         validate_exact_object ~context:"requeue decision" ~expected:[ "kind" ] fields
       in
       Ok Requeue_unconfirmed
     | "cancel_unconfirmed" ->
       let* () =
         validate_exact_object
           ~context:"cancel decision"
           ~expected:[ "kind"; "detail"; "outcome_ref" ]
           fields
       in
       let* detail_json = required "detail" fields in
       let* detail = exact_nonblank_string ~field:"decision.detail" detail_json in
       let* outcome_ref_json = required "outcome_ref" fields in
       let* outcome_ref =
         match outcome_ref_json with
         | `Null -> Ok None
         | value ->
           exact_nonblank_string ~field:"decision.outcome_ref" value
           |> Result.map (fun value -> Some value)
       in
       Ok (Cancel_unconfirmed { detail; outcome_ref })
     | unsupported -> Error (Unsupported_decision unsupported))
  | value ->
    Error
      (Object_required
         { context = "decision"; observed_kind = Json_util.kind_name value })
;;

let parse_request_components fields =
  let ( let* ) = Result.bind in
  let* revision_json = required "expected_revision" fields in
  let* expected_revision =
    canonical_nonnegative_int64 ~field:"expected_revision" revision_json
  in
  let* lease_id_json = required "lease_id" fields in
  let* lease_id = exact_nonblank_string ~field:"lease_id" lease_id_json in
  let* decision_json = required "decision" fields in
  let* decision = parse_decision decision_json in
  Ok { expected_revision; lease_id; decision }
;;

let parse_schema ~expected fields =
  let ( let* ) = Result.bind in
  let* schema_json = required "schema" fields in
  let* schema = exact_nonblank_string ~field:"schema" schema_json in
  if String.equal schema expected then Ok () else Error (Unsupported_schema schema)
;;

let parse_request = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* () =
      validate_exact_object
        ~context:"keeper chat recovery request"
        ~expected:[ "schema"; "expected_revision"; "lease_id"; "decision" ]
        fields
    in
    let* () = parse_schema ~expected:request_schema fields in
    parse_request_components fields
  | value ->
    Error
      (Object_required
         { context = "keeper chat recovery request"
         ; observed_kind = Json_util.kind_name value
         })
;;

let make ~keeper_name ~raw_receipt_id request =
  if not (Keeper_config.validate_name keeper_name)
  then Error (Invalid_keeper_name keeper_name)
  else
    match Keeper_chat_queue.Receipt_id.of_string raw_receipt_id with
    | Ok receipt_id -> Ok { keeper_name; receipt_id; request }
    | Error detail -> Error (Invalid_receipt_id detail)
;;

let parse_tool_command = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* () =
      validate_exact_object
        ~context:"keeper chat recovery tool command"
        ~expected:
          [ "schema"
          ; "keeper_name"
          ; "receipt_id"
          ; "expected_revision"
          ; "lease_id"
          ; "decision"
          ]
        fields
    in
    let* () = parse_schema ~expected:tool_command_schema fields in
    let* keeper_name_json = required "keeper_name" fields in
    let* keeper_name = exact_nonblank_string ~field:"keeper_name" keeper_name_json in
    let* receipt_id_json = required "receipt_id" fields in
    let* raw_receipt_id = exact_nonblank_string ~field:"receipt_id" receipt_id_json in
    let* request = parse_request_components fields in
    make ~keeper_name ~raw_receipt_id request
  | value ->
    Error
      (Object_required
         { context = "keeper chat recovery tool command"
         ; observed_kind = Json_util.kind_name value
         })
;;

let decision_label = function
  | Requeue_unconfirmed -> "requeue_unconfirmed"
  | Cancel_unconfirmed _ -> "cancel_unconfirmed"
;;

let execute ~now command =
  let resolution =
    match command.request.decision with
    | Requeue_unconfirmed -> Keeper_chat_queue.Requeue_unconfirmed
    | Cancel_unconfirmed { detail; outcome_ref } ->
      Keeper_chat_queue.Cancel_unconfirmed
        { cancelled_at = now; detail; outcome_ref }
  in
  Keeper_chat_queue.resolve_recovery_required
    ~keeper_name:command.keeper_name
    ~receipt_id:command.receipt_id
    ~expected_revision:command.request.expected_revision
    ~lease_id:command.request.lease_id
    ~resolution
;;

let audit config ~actor command ~outcome =
  try
    Audit_log.log_action
      config
      ~agent_id:actor
      ~action:(Audit_log.Custom "keeper_chat_queue_recovery_resolve")
      ~details:
        (`Assoc
          [ "keeper_name", `String command.keeper_name
          ; ( "receipt_id"
            , `String (Keeper_chat_queue.Receipt_id.to_string command.receipt_id) )
          ; ( "expected_revision"
            , `String (Int64.to_string command.request.expected_revision) )
          ; "lease_id", `String command.request.lease_id
          ; "decision", `String (decision_label command.request.decision)
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
    (report : Keeper_chat_queue.recovery_resolution_report) =
  let receipt : Keeper_chat_queue.receipt_view =
    { receipt_id = report.receipt_id; state = report.state }
  in
  `Assoc
    [ "schema", `String result_schema
    ; "ok", `Bool true
    ; "decision", `String (decision_label command.request.decision)
    ; ( "receipt"
      , Keeper_chat_receipt_projection.receipt_json
          ~keeper_name:command.keeper_name
          ~revision:report.revision
          receipt )
    ; "audit", audit
    ]
;;

let mutation_error_json ~audit error =
  `Assoc
    [ "schema", `String result_schema
    ; "ok", `Bool false
    ; "error", Keeper_chat_queue.mutation_error_to_json error
    ; "audit", audit
    ]
;;
