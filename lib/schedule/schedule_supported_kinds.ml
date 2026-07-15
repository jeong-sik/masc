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

let board_post = "masc.board_post"
let keeper_wake = "masc.keeper_wake"

let supported = [ keeper_wake ]

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

let keeper_wake_urgency_to_string = function
  | Keeper_wake_immediate -> "immediate"
  | Keeper_wake_normal -> "normal"
  | Keeper_wake_low -> "low"

let keeper_wake_urgency_of_string value =
  match List.find_opt (fun spec -> String.equal spec.label value) keeper_wake_urgencies with
  | Some spec -> Ok spec.value
  | None -> Error (Printf.sprintf "unknown urgency: %s" value)
;;

let keeper_wake_target_name_pattern = Safe_identifier.portable_name_pattern

let valid_keeper_wake_target_name =
  Safe_identifier.is_portable_name
;;

let keeper_wake_target_name_error ~field =
  Safe_identifier.portable_name_error ~field
;;
