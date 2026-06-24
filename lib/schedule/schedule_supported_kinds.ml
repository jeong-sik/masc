(** Supported schedule payload kinds — single source of truth.

    This neutral module is the contract surface between the schedule creation
    tool layer ({!Tool_schedule}) and the production consumer
    ({!Server_schedule_consumers}). Both reference this list so that a payload
    kind accepted at creation time is exactly one the consumer declares it can
    dispatch, and neither layer reaches across the [lib/tool] <-> [lib/server]
    boundary (software-development.md boundary-violation antipattern).

    Adding a kind here makes it (a) accepted by the creation validator and
    (b) declared as supported by the consumer. The consumer adapter must still
    implement [accepts]/[dispatch] for the kind — this list is the contract,
    the adapter is the implementation. A supported kind without an adapter
    branch surfaces at dispatch time as a failed execution with a recorded
    reason, rather than being silently accepted at creation and dying later:
    that silent accept-then-die gap is exactly what this module closes. *)

let supported = [ "masc.board_post" ]

let is_supported kind = List.mem kind supported

let supported_list_string () = String.concat ", " supported

let unsupported_error kind =
  Printf.sprintf
    "unsupported schedule payload kind: %s; supported: %s"
    kind
    (supported_list_string ())
;;
