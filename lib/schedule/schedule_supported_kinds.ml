(** Supported schedule payload kinds — single source of truth.

    This neutral module is the contract surface between the schedule creation
    tool layer ({!Tool_schedule}) and the production consumer
    ({!Server_schedule_consumers}). Both reference this list so that a payload
    kind accepted at creation time is exactly one the consumer declares it can
    dispatch, and neither layer reaches across the [lib/tool] <-> [lib/server]
    boundary (software-development.md boundary-violation antipattern).

    Adding a kind here makes it (a) declared as dispatchable by the consumer and
    (b) listed in {!unsupported_error}'s allow-list. It does NOT by itself make
    the kind accepted at creation: each side-effecting kind carries its own
    payload + risk-class contract, enforced by a per-kind branch in
    [Tool_schedule.validate_known_payload_request]. A kind listed here but
    without a validator branch stays rejected at creation as an unsupported
    side-effecting kind — closing the silent accept-then-die gap, just in the
    safe (reject) direction. So a new side-effecting kind needs BOTH the list
    entry and a validator branch. *)

let board_post = "masc.board_post"

let supported = [ board_post ]

let supported_list_string () = String.concat ", " supported

let unsupported_error kind =
  Printf.sprintf
    "unsupported schedule payload kind: %s; supported: %s"
    kind
    (supported_list_string ())
;;
