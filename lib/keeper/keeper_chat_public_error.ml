type kind =
  | Invalid_input | Unknown_operation | Not_queued | Idempotency_conflict
  | Native_call_unsettled | Store_unavailable | Owner_unavailable | Owner_stopping
  | Interrupt_failed | Operation_forbidden | Keeper_paused | Unknown_keeper
  | Journal_unreadable | Journal_corrupt | Journal_missing | Journal_pruned
  | Cursor_refusal of Keeper_chat_event_log.cursor_refusal
[@@deriving enumerate]

let all = all_of_kind

let code = function
  | Invalid_input -> "invalid_input"
  | Unknown_operation -> "unknown_operation"
  | Not_queued -> "not_queued"
  | Idempotency_conflict -> "idempotency_conflict"
  | Native_call_unsettled -> "native_call_unsettled"
  | Store_unavailable -> "store_unavailable"
  | Owner_unavailable -> "owner_unavailable"
  | Owner_stopping -> "owner_stopping"
  | Interrupt_failed -> "interrupt_failed"
  | Operation_forbidden -> "operation_forbidden"
  | Keeper_paused -> "keeper_paused"
  | Unknown_keeper -> "unknown_keeper"
  | Journal_unreadable -> "journal_unreadable"
  | Journal_corrupt -> "journal_corrupt"
  | Journal_missing -> "journal_missing"
  | Journal_pruned -> "journal_pruned"
  | Cursor_refusal refusal -> Keeper_chat_event_log.cursor_refusal_to_wire refusal
;;

let message = function
  | Invalid_input -> "The request is invalid."
  | Unknown_operation -> "The operation was not found."
  | Not_queued -> "The operation is no longer queued."
  | Idempotency_conflict -> "This operation identity already belongs to another request."
  | Native_call_unsettled -> "The operation has an unsettled native call."
  | Store_unavailable -> "The operation store is unavailable."
  | Owner_unavailable -> "The Keeper owner is unavailable; the request was not accepted."
  | Owner_stopping -> "The Keeper owner is stopping."
  | Interrupt_failed -> "The active turn could not be interrupted."
  | Operation_forbidden -> "The operation belongs to another actor."
  | Keeper_paused -> "Resume the Keeper before prioritizing this operation."
  | Unknown_keeper -> "The Keeper was not found."
  | Journal_unreadable -> "The event journal is unavailable."
  | Journal_corrupt -> "The event journal requires operator attention."
  | Journal_missing -> "No event journal exists for this turn."
  | Journal_pruned -> "No event journal is available for the settled operation."
  | Cursor_refusal (_ : Keeper_chat_event_log.cursor_refusal) ->
    "The event cursor cannot be used for this journal."
;;

let of_code wire = List.find_opt (fun kind -> String.equal (code kind) wire) all

type pre_acceptance =
  | Not_accepted
  | Acceptance_unknown

(* The kinds a submission can be refused with before any Owner wrote it are
   [Not_accepted]. Every other kind keeps the client's operation fenced until
   a read of the exact operation settles it. *)
let pre_acceptance = function
  | Invalid_input | Unknown_operation | Not_queued | Owner_stopping | Owner_unavailable ->
    Not_accepted
  | Idempotency_conflict | Native_call_unsettled | Store_unavailable | Interrupt_failed
  | Operation_forbidden | Keeper_paused | Unknown_keeper
  | Journal_unreadable | Journal_corrupt | Journal_missing | Journal_pruned
  | Cursor_refusal (_ : Keeper_chat_event_log.cursor_refusal) ->
    Acceptance_unknown
;;
