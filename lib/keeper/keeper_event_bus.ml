(** Keeper_event_bus — Process-scoped OAS Event_bus reference.

    Holds the shared Event_bus instance set once at server bootstrap.
    Separate module to avoid dependency cycles: Keeper_keepalive and
    Keeper_agent_run both depend on keeper modules that form cycles
    if they reference each other.

    @since 2.255.0 *)

let bus_ref : Oas.Event_bus.t option Atomic.t = Atomic.make None

let set bus = Atomic.set bus_ref (Some bus)
let get () = Atomic.get bus_ref
