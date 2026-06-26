(** Keeper_event_bus — Per-domain OAS Event_bus reference.

    Holds the shared Event_bus instance set once per OCaml domain at
    server bootstrap.  Separate module to avoid dependency cycles:
    Keeper_keepalive and Keeper_agent_run both depend on keeper
    modules that form cycles if they reference each other.

    Stored in [Domain.DLS] so access is domain-local.  Keeper
    supervision runs on the owning Eio domain, so this is equivalent
    to the previous process-scoped Atomic semantics while removing
    the module-level global.

    @since 2.255.0 *)

let bus_key : Agent_sdk.Event_bus.t option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

let set bus = Domain.DLS.set bus_key (Some bus)
let get () = Domain.DLS.get bus_key
