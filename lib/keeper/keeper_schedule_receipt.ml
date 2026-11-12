open Result.Syntax
module Outbox = Keeper_client_tool_outbox

type ending =
  | Delivered of { schedule_id : string; message : string }
  | Unfinished of { cause : string }

(* The outbox format keeps a vendor session id in [thread_id] and a vendor turn
   id in [turn_id]. A schedule has neither, so the first names the producer and
   the second repeats the receipt key, as a background run's receipt
   does with its request id. *)
let producer_label = "schedule_wake"

(* The call this receipt answers is the one that created the schedule. The
   stored payload no longer holds that call's arguments (the watch is removed
   when it fires and the message is replaced), so none are recorded. *)
let tool_name = "masc_schedule_create"

let response_json ~receipt_key = function
  | Delivered { schedule_id; message } ->
    `Assoc
      [ "request_id", `String receipt_key
      ; "schedule_id", `String schedule_id
      ; "outcome", `String "completed"
      ; "result", `Assoc [ "message", `String message ]
      ]
  | Unfinished { cause } ->
    `Assoc
      [ "request_id", `String receipt_key
      ; "outcome", `String "unfinished"
      ; "result", `Assoc [ "ok", `Bool false; "message", `String cause ]
      ]
;;

let receipt ~receipt_key ending : Outbox.receipt =
  let call_id = Schedule_supported_kinds.receipt_key_to_string receipt_key in
  { thread_id = producer_label
  ; turn_id = call_id
  ; call_id
  ; tool_name
  ; arguments = Outbox.Unknown
  ; response = response_json ~receipt_key:call_id ending
  }
;;

let notify ~base_path ~keeper_name ~receipt_key =
  match Keeper_client_tool_outbox_wake.notify ~base_path ~keeper_name with
  | Ok () -> ()
  | Error detail ->
    Log.Keeper.warn
      ~keeper_name
      "schedule receipt %s: wake deferred: %s"
      (Schedule_supported_kinds.receipt_key_to_string receipt_key)
      detail
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Log.Keeper.warn
      ~keeper_name
      "schedule receipt %s: wake raised: %s"
      (Schedule_supported_kinds.receipt_key_to_string receipt_key)
      (Printexc.to_string exn)
;;

let retain_once ~base_path ~keeper_name ~receipt_key ending =
  let* snapshot = Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Every_receipt in
  if Outbox.contains_call
       snapshot
       ~call_id:(Schedule_supported_kinds.receipt_key_to_string receipt_key)
  then Ok ()
  else Outbox.retain ~base_path ~keeper_name (receipt ~receipt_key ending)
;;

let deliver ~base_path ~keeper_name ~receipt_key ending =
  let* () = retain_once ~base_path ~keeper_name ~receipt_key ending in
  notify ~base_path ~keeper_name ~receipt_key;
  Ok ()
;;

let source_lost_cause =
  "The receipt will not come: the schedule ended without writing it, was \
   cancelled or expired, or no longer delivers receipts. Check the state it was \
   to report."
;;

(* The wait that asked for this schedule is resolved by the caller afterwards,
   so this does not wake the Keeper: a wake before the wait is resolved would
   find the receipt owned and read nothing. *)
let retain_unfinished ~base_path ~keeper_name ~receipt_key =
  retain_once
    ~base_path
    ~keeper_name
    ~receipt_key
    (Unfinished { cause = source_lost_cause })
;;
