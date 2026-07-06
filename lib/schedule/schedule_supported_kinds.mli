(** Supported schedule payload kinds — single source of truth.

    This neutral module is the contract surface between the schedule creation
    tool layer ({!Tool_schedule}) and the production consumer
    ({!Server_schedule_consumers}); see {!Schedule_supported_kinds} for the
    full design rationale. Neither layer reaches across the
    [lib/tool] <-> [lib/server] boundary. *)

val board_post : string
(** Schedule payload kind for creating a board post. *)

val supported : string list
(** Dispatchable side-effecting payload kinds the production consumer can run.
    This is the consumer's dispatch set and the allow-list in
    {!unsupported_error}. Note: the creation validator does NOT grant
    acceptance from this list alone — each side-effecting kind carries its own
    payload + risk-class contract enforced by a per-kind branch in
    [Tool_schedule.validate_known_payload_request]. So adding a side-effecting
    kind requires BOTH an entry here (consumer dispatch + reject message) AND a
    validator branch (creation acceptance); the list alone leaves it rejected at
    creation as an unsupported side-effecting kind. *)

val supported_list_string : unit -> string

val unsupported_error : string -> string
(** Error message for a payload kind outside {!supported}. *)
