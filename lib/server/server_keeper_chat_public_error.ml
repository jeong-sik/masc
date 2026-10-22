type kind = Keeper_chat_public_error.kind =
  | Invalid_input | Unknown_operation | Not_queued | Idempotency_conflict
  | Native_call_unsettled | Store_unavailable | Owner_unavailable | Owner_stopping
  | Interrupt_failed | Operation_forbidden | Keeper_paused | Unknown_keeper
  | Journal_unreadable | Journal_corrupt | Journal_missing | Journal_pruned
  | Cursor_refusal of Keeper_chat_event_log.cursor_refusal

type t =
  { status : Httpun.Status.t
  ; code : string
  ; message : string
  ; incident_id : string
  }

let status : kind -> Httpun.Status.t = function
  | Invalid_input -> `Bad_request
  | Unknown_operation -> `Not_found
  | Not_queued -> `Conflict
  | Idempotency_conflict -> `Conflict
  | Native_call_unsettled -> `Conflict
  | Store_unavailable -> `Service_unavailable
  | Owner_unavailable -> `Service_unavailable
  | Owner_stopping -> `Service_unavailable
  | Interrupt_failed -> `Service_unavailable
  | Operation_forbidden -> `Forbidden
  | Keeper_paused -> `Conflict
  | Unknown_keeper -> `Not_found
  | Journal_unreadable -> `Service_unavailable
  | Journal_corrupt -> `Service_unavailable
  | Journal_missing -> `Not_found
  | Journal_pruned -> `Gone
  | Cursor_refusal (_ : Keeper_chat_event_log.cursor_refusal) -> `Bad_request
;;

let make ~incident_id kind =
  { status = status kind
  ; code = Keeper_chat_public_error.code kind
  ; message = Keeper_chat_public_error.message kind
  ; incident_id
  }
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
