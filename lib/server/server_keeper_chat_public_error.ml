type kind =
  | Invalid_input | Unknown_operation | Not_queued | Idempotency_conflict
  | Native_call_unsettled | Store_unavailable | Owner_stopping | Interrupt_failed
  | Operation_forbidden | Keeper_paused | Unknown_keeper
  | Journal_unreadable | Journal_corrupt | Journal_missing | Journal_pruned
  | Cursor_refusal of Keeper_chat_event_log.cursor_refusal

type t =
  { status : Httpun.Status.t
  ; code : string
  ; message : string
  ; incident_id : string
  }

let make ~incident_id kind =
  let status, code, message = match kind with
    | Invalid_input -> `Bad_request, "invalid_input", "The request is invalid."
    | Unknown_operation -> `Not_found, "unknown_operation", "The operation was not found."
    | Not_queued -> `Conflict, "not_queued", "The operation is no longer queued."
    | Idempotency_conflict -> `Conflict, "idempotency_conflict",
        "This operation identity already belongs to another request."
    | Native_call_unsettled -> `Conflict, "native_call_unsettled",
        "The operation has an unsettled native call."
    | Store_unavailable -> `Service_unavailable, "store_unavailable",
        "The operation store is unavailable."
    | Owner_stopping -> `Service_unavailable, "owner_stopping",
        "The Keeper owner is stopping."
    | Interrupt_failed -> `Service_unavailable, "interrupt_failed",
        "The active turn could not be interrupted."
    | Operation_forbidden -> `Forbidden, "operation_forbidden",
        "The operation belongs to another actor."
    | Keeper_paused -> `Conflict, "keeper_paused",
        "Resume the Keeper before prioritizing this operation."
    | Unknown_keeper -> `Not_found, "unknown_keeper", "The Keeper was not found."
    | Journal_unreadable -> `Service_unavailable, "journal_unreadable",
        "The event journal is unavailable."
    | Journal_corrupt -> `Service_unavailable, "journal_corrupt",
        "The event journal requires operator attention."
    | Journal_missing -> `Not_found, "journal_missing",
        "No event journal exists for this turn."
    | Journal_pruned -> `Gone, "journal_pruned",
        "No event journal is available for the settled operation."
    | Cursor_refusal refusal -> `Bad_request,
        Keeper_chat_event_log.cursor_refusal_to_wire refusal,
        "The event cursor cannot be used for this journal."
  in
  {status;code;message;incident_id}
;;

let to_json error =
  `Assoc
    [ "schema", `String "masc.keeper_chat_operation.error.v1"
    ; "error", `String error.code
    ; "message", `String error.message
    ; "incident_id", `String error.incident_id
    ]
;;

let failure_fields error =
  [ "detail", `String error.message
  ; "error_code", `String error.code
  ; "incident_id", `String error.incident_id
  ]
;;

let prioritized_operation_json ~request_id ~signalled ~interrupt_error =
  let detail, error_fields = match interrupt_error with
    | Some error -> error.message,
        [ "error_code", `String error.code
        ; "incident_id", `String error.incident_id ]
    | None ->
      (if signalled then
         "queued with priority; interrupt received; waiting for the turn to settle"
       else "queued with priority; no matching observed turn was interrupted"), []
  in
  `Assoc
    ([ "request_id", `String request_id; "prioritized", `Bool true
     ; "signalled", `Bool signalled; "detail", `String detail ] @ error_fields)
;;
