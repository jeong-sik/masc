(** Private single effect boundary for Agent execution events.

    This module adds no policy or state. It preserves the current
    {!Durable_event} authority while keeping append failure propagation in one
    production writer. *)

type t = Durable_event.journal
type event = Durable_event.event

val append : t -> event -> unit
