(** Masc_event_bus — Process-scoped MASC-owned Event_bus instance.

    Domain boundary: MASC publishes domain-specific events (broadcasts,
    heartbeats, task transitions, keeper lifecycle, etc.) on its own bus
    rather than onto OAS's shared Event_bus. OAS's [event_bus.mli:103-107]
    says: "External publishers should use their own Event_bus.t instance
    for domain-specific events rather than publishing onto OAS's bus.
    Treating OAS's Event_bus as a general-purpose telemetry channel
    creates cross-layer coupling."

    Same type as [Oas.Event_bus.t] — we re-use the library rather
    than re-inventing the transport. Different instance, different
    subscribers, different lifecycle.

    Process-scoped singleton (same pattern as [Keeper_event_bus]): set
    once at server bootstrap, read from publishers throughout the
    process.

    @since 2.353.0 *)

let bus_ref : Oas.Event_bus.t option Atomic.t = Atomic.make None
let set bus = Atomic.set bus_ref (Some bus)
let get () = Atomic.get bus_ref
