open Result.Syntax
module Outbox = Keeper_client_tool_outbox

type ending =
  | Delivered of { message : string }
  | Unfinished of { cause : string }

(* The outbox format keeps a vendor session id in [thread_id] and a vendor turn
   id in [turn_id]. A schedule has neither, so the first names the producer and
   the second repeats the schedule id, as a background run's receipt
   does with its request id. *)
let producer_label = "schedule_wake"

(* The call this receipt answers is the one that created the schedule. The
   stored payload no longer holds that call's arguments (the watch is removed
   when it fires and the message is replaced), so none are recorded. *)
let tool_name = "masc_schedule_create"

let response_json ~schedule_id = function
  | Delivered { message } ->
    `Assoc
      [ "request_id", `String schedule_id
      ; "outcome", `String "completed"
      ; "result", `Assoc [ "message", `String message ]
      ]
  | Unfinished { cause } ->
    `Assoc
      [ "request_id", `String schedule_id
      ; "outcome", `String "unfinished"
      ; "result", `Assoc [ "ok", `Bool false; "message", `String cause ]
      ]
;;

let receipt ~schedule_id ending : Outbox.receipt =
  { thread_id = producer_label
  ; turn_id = schedule_id
  ; call_id = schedule_id
  ; tool_name
  ; arguments = Outbox.Unknown
  ; response = response_json ~schedule_id ending
  }
;;

let notify ~base_path ~keeper_name ~schedule_id =
  match Keeper_client_tool_outbox_wake.notify ~base_path ~keeper_name with
  | Ok () -> ()
  | Error detail ->
    Log.Keeper.warn
      ~keeper_name
      "schedule receipt %s: wake deferred: %s"
      schedule_id
      detail
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Log.Keeper.warn
      ~keeper_name
      "schedule receipt %s: wake raised: %s"
      schedule_id
      (Printexc.to_string exn)
;;

let deliver ~base_path ~keeper_name ~schedule_id ending =
  let* snapshot = Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Every_receipt in
  let* () =
    if Outbox.contains_call snapshot ~call_id:schedule_id
    then Ok ()
    else Outbox.retain ~base_path ~keeper_name (receipt ~schedule_id ending)
  in
  notify ~base_path ~keeper_name ~schedule_id;
  Ok ()
;;
