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
  | Cancel_active_lease of Cancellation.request
  | Transfer_owner of
      { to_keeper : string
      ; request : Transfer.request
      }
  | Settle_from_source_terminal of Source_terminal.request

let ( let* ) = Result.bind
let schema = "masc.keeper.paused-work.operator-request.v1"

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

let finite_float_of_yojson field = function
  | `Float value when Float.is_finite value -> Ok value
  | `Int value -> Ok (Float.of_int value)
  | `Intlit value ->
    (match Float.of_string_opt value with
     | Some value when Float.is_finite value -> Ok value
     | Some _ | None -> Error (field ^ " must be a finite number"))
  | _ -> Error (field ^ " must be a finite number")
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
    ; ("owner_generation", `Int owner_generation)
    ; ("schema", `String request_schema)
    ]
    when String.equal request_schema schema ->
    let* operator_operation_id =
      nonblank "operator_operation_id" operator_operation_id
    in
    let* owner_generation = nonnegative_int "owner_generation" owner_generation in
    Ok (Resume_owner Resume.{ owner_generation; operator_operation_id })
  | _ -> Error "resume_owner request fields are not exact"
;;

let parse_cancel_pending = function
  | [ ("operation", `String "cancel_accepted")
    ; ("operator_operation_id", `String operator_operation_id)
    ; ("owner_generation", `Int owner_generation)
    ; ("reason", `String reason)
    ; ("schema", `String request_schema)
    ; ("settled_at", settled_at_json)
    ; ("source", source_json)
    ; ("source_revision", source_revision_json)
    ; ("source_state", `String "pending")
    ]
    when String.equal request_schema schema ->
    let* source = Queue.stimulus_of_yojson source_json in
    let* source_revision = int64_of_yojson "source_revision" source_revision_json in
    let* source_revision = nonnegative_int64 "source_revision" source_revision in
    let* settled_at = finite_float_of_yojson "settled_at" settled_at_json in
    let* operator_operation_id =
      nonblank "operator_operation_id" operator_operation_id
    in
    let* reason = nonblank "reason" reason in
    let* owner_generation = nonnegative_int "owner_generation" owner_generation in
    Ok
      (Cancel_pending
         Cancellation.
           { source
           ; source_revision
           ; owner_generation
           ; operator_operation_id
           ; reason
           ; settled_at
           })
  | _ -> Error "pending cancel_accepted request fields are not exact"
;;

let parse_cancel_active_lease = function
  | [ ("lease", lease_json)
    ; ("operation", `String "cancel_accepted")
    ; ("operator_operation_id", `String operator_operation_id)
    ; ("owner_generation", `Int owner_generation)
    ; ("reason", `String reason)
    ; ("schema", `String request_schema)
    ; ("settled_at", settled_at_json)
    ; ("source_revision", source_revision_json)
    ; ("source_state", `String "active_lease")
    ]
    when String.equal request_schema schema ->
    let* lease = Queue_state.lease_of_yojson lease_json in
    let* source_revision = int64_of_yojson "source_revision" source_revision_json in
    let* source_revision = nonnegative_int64 "source_revision" source_revision in
    let* settled_at = finite_float_of_yojson "settled_at" settled_at_json in
    let* operator_operation_id =
      nonblank "operator_operation_id" operator_operation_id
    in
    let* reason = nonblank "reason" reason in
    let* owner_generation = nonnegative_int "owner_generation" owner_generation in
    Ok
      (Cancel_active_lease
         Cancellation.
           { source_revision
           ; owner_generation
           ; lease
           ; operator_operation_id
           ; reason
           ; settled_at
           })
  | _ -> Error "active-lease cancel_accepted request fields are not exact"
;;

let parse_transfer = function
  | [ ("continuation_binding", continuation_binding_json)
    ; ("operation", `String "transfer_owner")
    ; ("operator_operation_id", `String operator_operation_id)
    ; ("owner_generation", `Int owner_generation)
    ; ("schema", `String request_schema)
    ; ("settled_at", settled_at_json)
    ; ("source", source_json)
    ; ("source_revision", source_revision_json)
    ; ("target_generation", `Int target_generation)
    ; ("to_keeper", `String to_keeper)
    ]
    when String.equal request_schema schema ->
    let* source = Queue.stimulus_of_yojson source_json in
    let* source_revision = int64_of_yojson "source_revision" source_revision_json in
    let* source_revision = nonnegative_int64 "source_revision" source_revision in
    let* settled_at = finite_float_of_yojson "settled_at" settled_at_json in
    let* continuation_binding =
      Disposition.continuation_binding_of_yojson continuation_binding_json
    in
    let* operator_operation_id =
      nonblank "operator_operation_id" operator_operation_id
    in
    let* to_keeper = nonblank "to_keeper" to_keeper in
    let* owner_generation = nonnegative_int "owner_generation" owner_generation in
    let* target_generation = nonnegative_int "target_generation" target_generation in
    Ok
      (Transfer_owner
         { to_keeper
         ; request =
             Transfer.
               { source
               ; source_revision
               ; owner_generation
               ; target_generation
               ; continuation_binding
               ; operator_operation_id
               ; settled_at
               }
         })
  | _ -> Error "transfer_owner request fields are not exact"
;;

let parse_source_terminal = function
  | [ ("operation", `String "settle_from_source_terminal")
    ; ("operator_operation_id", `String operator_operation_id)
    ; ("owner_generation", `Int owner_generation)
    ; ("schema", `String request_schema)
    ; ("settled_at", settled_at_json)
    ; ("source", source_json)
    ; ("source_receipt_kind", `String source_receipt_kind)
    ; ("source_revision", source_revision_json)
    ]
    when String.equal request_schema schema ->
    let* source = Queue.stimulus_of_yojson source_json in
    let* source_revision = int64_of_yojson "source_revision" source_revision_json in
    let* source_revision = nonnegative_int64 "source_revision" source_revision in
    let* settled_at = finite_float_of_yojson "settled_at" settled_at_json in
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
    let* owner_generation = nonnegative_int "owner_generation" owner_generation in
    Ok
      (Settle_from_source_terminal
         Source_terminal.
           { source
           ; source_revision
           ; owner_generation
           ; source_receipt
           ; operator_operation_id
           ; settled_at
           })
  | _ -> Error "settle_from_source_terminal request fields are not exact"
;;

let of_yojson = function
  | `Assoc fields ->
    let fields = sorted fields in
    (match List.assoc_opt "operation" fields, List.assoc_opt "source_state" fields with
     | Some (`String "resume_owner"), _ -> parse_resume fields
     | Some (`String "cancel_accepted"), Some (`String "pending") ->
       parse_cancel_pending fields
     | Some (`String "cancel_accepted"), Some (`String "active_lease") ->
       parse_cancel_active_lease fields
     | Some (`String "transfer_owner"), _ -> parse_transfer fields
     | Some (`String "settle_from_source_terminal"), _ ->
       parse_source_terminal fields
     | Some (`String operation), _ ->
       Error (Printf.sprintf "unsupported paused-work operation %S" operation)
     | Some _, _ -> Error "operation must be a string"
     | None, _ -> Error "operation is required")
  | _ -> Error "paused-work operator request must be an object"
;;
