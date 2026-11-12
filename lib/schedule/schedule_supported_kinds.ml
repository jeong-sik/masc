(** Supported schedule payload kinds — single source of truth.

    This neutral module is the contract surface between the schedule creation
    tool layer ({!Tool_schedule}) and the production consumer
    ({!Server_schedule_consumers}). Both reference this list so that a payload
    kind accepted at creation time is exactly one the consumer declares it can
    dispatch, and neither layer reaches across the [lib/tool] <-> [lib/server]
    boundary (software-development.md boundary-violation antipattern).

    Adding a kind here makes it (a) declared as dispatchable by the consumer and
    (b) listed in {!unsupported_error}'s allow-list. It does NOT by itself make
    the kind accepted at creation: each kind carries its own objective payload
    schema contract, enforced by a per-kind branch in
    [Tool_schedule.validate_known_payload_request]. A kind listed here but
    without a validator branch stays rejected at creation as an unsupported
    kind. So a new kind needs both the list entry and a validator branch. *)

let keeper_wake = "masc.keeper_wake"

(* One action handed to a declared Lane Add-on installation's live worker
   (RFC operator-quiz §4.7). *)
let lane_act = "masc.lane_act"

let supported = [ keeper_wake; lane_act ]

let supported_list_string () = String.concat ", " supported

let unsupported_error kind =
  Printf.sprintf
    "unsupported schedule payload kind: %s; supported: %s"
    kind
    (supported_list_string ())
;;

type keeper_wake_urgency =
  | Keeper_wake_immediate
  | Keeper_wake_normal
  | Keeper_wake_low

let default_keeper_wake_urgency = Keeper_wake_normal

type keeper_wake_urgency_spec =
  { label : string
  ; value : keeper_wake_urgency
  }

let keeper_wake_urgencies =
  [ { label = "immediate"; value = Keeper_wake_immediate }
  ; { label = "normal"; value = Keeper_wake_normal }
  ; { label = "low"; value = Keeper_wake_low }
  ]
;;

let keeper_wake_urgency_of_string value =
  match List.find_opt (fun spec -> String.equal spec.label value) keeper_wake_urgencies with
  | Some spec -> Ok spec.value
  | None -> Error (Printf.sprintf "unknown urgency: %s" value)
;;

(* How a due Keeper wake reaches its Keeper. [Keeper_wake_to_queue] puts a new
   message in the Keeper's event queue. [Keeper_wake_to_receipt] writes a
   tool-result receipt the way a background run's result is written, so a turn
   that ended on [keeper_receipt_wait] for this schedule continues with it. *)
type keeper_wake_delivery =
  | Keeper_wake_to_queue
  | Keeper_wake_to_receipt

let default_keeper_wake_delivery = Keeper_wake_to_queue

type keeper_wake_delivery_spec =
  { delivery_label : string
  ; delivery_value : keeper_wake_delivery
  }

let keeper_wake_deliveries =
  [ { delivery_label = "queue"; delivery_value = Keeper_wake_to_queue }
  ; { delivery_label = "receipt"; delivery_value = Keeper_wake_to_receipt }
  ]
;;

let keeper_wake_delivery_of_string value =
  match
    List.find_opt
      (fun spec -> String.equal spec.delivery_label value)
      keeper_wake_deliveries
  with
  | Some spec -> Ok spec.delivery_value
  | None ->
    Error
      (Printf.sprintf
         "unknown delivery: %s; known: %s"
         value
         (String.concat ", " (List.map (fun spec -> spec.delivery_label) keeper_wake_deliveries)))
;;

(* The name of one receipt-delivering schedule: the [call_id] of the receipt it
   writes and the id a wait is recorded under. [schedule_id] cannot be that name.
   A Keeper may pick it, so the same text can name an Execute request or a
   schedule created again after the first was pruned, and a receipt still in the
   outbox would answer the wrong one. The key is issued when the row is created
   and is in the row's body, so a run watch that settles keeps it. *)
type receipt_key = string

let receipt_key_of_string value =
  if String.equal value ""
  then Error "receipt_key is empty"
  else Ok value
;;

let receipt_key_to_string key = key

(* The colon is one a request id cannot hold. The receipt wait sweep tells a
   schedule's key from a request id by the request store refusing the id, so a
   key must never be a valid request id. A test holds the two together.
   NDT-OK: a key must differ from every other key ever issued, so it is drawn
   from the process random source when the schedule is written. *)
let fresh_receipt_key () = Random_id.prefixed ~prefix:"schedule-receipt:" ~bytes:16

let valid_keeper_wake_target_name =
  Safe_identifier.is_portable_name
;;

let keeper_wake_target_name_error ~field =
  Safe_identifier.portable_name_error ~field
;;
