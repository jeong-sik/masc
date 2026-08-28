(** Process-host lifecycle visible to official-client transports.

    The main executable owns signal handling while this library owns child
    provider transports. This tiny atomic bridge lets an EOF observed during
    graceful shutdown retain its cause instead of degrading to
    ["stdout closed"]. *)

val mark_shutting_down : unit -> unit
(** Mark the process as entering graceful shutdown. Sticky and idempotent. *)

val is_shutting_down : unit -> bool
(** Whether {!mark_shutting_down} has been called in this process. *)
