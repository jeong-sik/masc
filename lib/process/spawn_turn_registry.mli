(** The spawn registry a turn is using, bound the way its switch is.

    RFC spawn-a-process-that-outlives-the-call §6 asked whose switch a spawned
    process should belong to. This is the answer for now: the turn's. The
    registry is bound on the same fiber, for the same span, as
    [Eio_context.with_turn_switch], so a handle is meaningful exactly as long
    as the process it names can still be running.

    A registry held longer than that would keep answering for processes the
    switch already ended, and would need a retention bound to stop the table
    growing -- a cap with nothing to say. Binding it to the turn removes the
    question: a handle from an earlier turn finds no registry entry, and
    "the process ended with its turn" is what the caller is told. *)

val with_turn_registry : Spawn_registry.t option -> (unit -> 'a) -> 'a
(** Bind [registry] for the current fiber and the fibers forked from it, the
    way [Eio_context.with_turn_switch] binds a switch. Call from inside the
    turn body, so what reads it during the turn is what the turn created.

    [None] binds nothing, so a turn whose registry could not be created runs
    without one and the spawn tools say so, rather than the turn failing over a
    capability it may never use. *)

val get_opt : unit -> Spawn_registry.t option
(** [None] outside a turn, and inside one that has no registry. A tool that
    needs a registry and finds none says so rather than making one nothing
    else can reach. *)
