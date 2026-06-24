(** Supported schedule payload kinds — single source of truth.

    This neutral module is the contract surface between the schedule creation
    tool layer ({!Tool_schedule}) and the production consumer
    ({!Server_schedule_consumers}); see {!Schedule_supported_kinds} for the
    full design rationale. Both layers reference this list so that a payload
    kind accepted at creation is exactly one the consumer declares it can
    dispatch, with neither layer reaching across the [lib/tool] <-> [lib/server]
    boundary. *)

val supported : string list
(** Dispatchable side-effecting payload kinds the production consumer can run.
    Adding a kind here makes it accepted by the creation validator and declared
    as supported by the consumer; the consumer adapter must still implement
    [accepts]/[dispatch] for it. *)

val is_supported : string -> bool

val supported_list_string : unit -> string

val unsupported_error : string -> string
(** Error message for a payload kind outside {!supported}. *)
