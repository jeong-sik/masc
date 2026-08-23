module Queue = Keeper_event_queue
module Queue_state = Keeper_event_queue_state
module Disposition = Keeper_paused_work_disposition_receipt
module Resume = Keeper_paused_work_resume_transaction
module Cancellation = Keeper_paused_work_cancellation_transaction
module Transfer = Keeper_paused_work_transfer_transaction
module Source_terminal = Keeper_paused_work_source_terminal_transaction

type t =
  | Resume_owner of Resume.request
  | Cancel_pending of Cancellation.pending_request
  | Transfer_owner of
      { to_keeper : string
      ; request : Transfer.request
      }
  | Ack_source_terminal of Source_terminal.request

let ( let* ) = Result.bind
let schema = "masc.keeper.paused-work.operator-request.v4"

let sorted fields =
  List.sort (fun (left, _) (right, _) -> String.compare left right) fields
;;

let int64_of_yojson field = function
  | `Int value -> Ok (Int64.of_int value)
  | `Intlit value ->
    (match Int64.of_string_opt value with
     | Some value -> Ok value
     | None -> Error (field ^ " must be an int64"))
  | _ -> Error (field ^ " must be an int64")
;;

let nonblank field value =
  if String.equal (String.trim value) ""
  then Error (field ^ " must not be blank")
  else Ok value
;;

let nonnegative_int field value =
  if value < 0 then Error (field ^ " must not be negative") else Ok value
;;

let nonnegative_int64 field value =
  if Int64.compare value 0L < 0
  then Error (field ^ " must not be negative")
  else Ok value
;;

let parse_resume = function
  | [ ("operation", `String "resume_owner")
    ; ("operator_operation_id", `String operator_operation_id)
    ; ("schema", `String request_schema)
    ]
    when String.equal request_schema schema ->
    let* operator_operation_id =
      nonblank "operator_operation_id" operator_operation_id
    in
    Ok (Resume_owner Resume.{ operator_operation_id })
  | _ -> Error "resume_owner request fields are not exact"
;;

let parse_cancel_pending = function
  | [ ("operation", `String "cancel_accepted")
    ; ("operator_operation_id", `String operator_operation_id)
    ; ("reason", `String reason)
    ; ("schema", `String request_schema)
    ; ("source", source_json)
    ; ("source_incarnation", source_incarnation_json)
    ; ("source_state", `String "pending")
    ]
    when String.equal request_schema schema ->
    let* source = Queue.stimulus_of_yojson source_json in
    let* source_incarnation = int64_of_yojson "source_incarnation" source_incarnation_json in
    let* source_incarnation = nonnegative_int64 "source_incarnation" source_incarnation in
    let* operator_operation_id =
      nonblank "operator_operation_id" operator_operation_id
    in
    let* reason = nonblank "reason" reason in
    Ok
      (Cancel_pending
         Cancellation.
           { source
           ; source_incarnation
           ; operator_operation_id
           ; reason
           })
  | _ -> Error "pending cancel_accepted request fields are not exact"
;;

let parse_transfer = function
  | [ ("continuation_binding", continuation_binding_json)
    ; ("operation", `String "transfer_owner")
    ; ("operator_operation_id", `String operator_operation_id)
    ; ("schema", `String request_schema)
    ; ("source", source_json)
    ; ("source_incarnation", source_incarnation_json)
    ; ("to_keeper", `String to_keeper)
    ]
    when String.equal request_schema schema ->
    let* source = Queue.stimulus_of_yojson source_json in
    let* source_incarnation = int64_of_yojson "source_incarnation" source_incarnation_json in
    let* source_incarnation = nonnegative_int64 "source_incarnation" source_incarnation in
    let* continuation_binding =
      Disposition.continuation_binding_of_yojson continuation_binding_json
    in
    let* operator_operation_id =
      nonblank "operator_operation_id" operator_operation_id
    in
    let* to_keeper = nonblank "to_keeper" to_keeper in
    Ok
      (Transfer_owner
         { to_keeper
         ; request =
             Transfer.
               { source
               ; source_incarnation
               ; continuation_binding
               ; operator_operation_id
               }
         })
  | _ -> Error "transfer_owner request fields are not exact"
;;

let parse_source_terminal = function
  | [ ("operation", `String "ack_source_terminal")
    ; ("operator_operation_id", `String operator_operation_id)
    ; ("schema", `String request_schema)
    ; ("source", source_json)
    ; ("source_incarnation", source_incarnation_json)
    ; ("source_receipt_kind", `String source_receipt_kind)
    ]
    when String.equal request_schema schema ->
    let* source = Queue.stimulus_of_yojson source_json in
    let* source_incarnation = int64_of_yojson "source_incarnation" source_incarnation_json in
    let* source_incarnation = nonnegative_int64 "source_incarnation" source_incarnation in
    let* source_receipt = Queue_state.source_terminal_receipt_of_stimulus source in
    let* () =
      if
        String.equal
          source_receipt_kind
          (Disposition.source_terminal_receipt_kind source_receipt)
      then Ok ()
      else Error "source_receipt_kind does not match the exact source payload"
    in
    let* operator_operation_id =
      nonblank "operator_operation_id" operator_operation_id
    in
    Ok
      (Ack_source_terminal
         Source_terminal.
           { source
           ; source_incarnation
           ; source_receipt
           ; operator_operation_id
           })
  | _ -> Error "ack_source_terminal request fields are not exact"
;;

let of_yojson = function
  | `Assoc fields ->
    let fields = sorted fields in
    (match List.assoc_opt "operation" fields, List.assoc_opt "source_state" fields with
     | Some (`String "resume_owner"), _ -> parse_resume fields
     | Some (`String "cancel_accepted"), Some (`String "pending") ->
       parse_cancel_pending fields
     | Some (`String "cancel_accepted"), Some _ ->
       Error "cancel_accepted source_state must be pending"
     | Some (`String "transfer_owner"), _ -> parse_transfer fields
     | Some (`String "ack_source_terminal"), _ ->
       parse_source_terminal fields
     | Some (`String operation), _ ->
       Error (Printf.sprintf "unsupported paused-work operation %S" operation)
     | Some _, _ -> Error "operation must be a string"
     | None, _ -> Error "operation is required")
  | _ -> Error "paused-work operator request must be an object"
;;
