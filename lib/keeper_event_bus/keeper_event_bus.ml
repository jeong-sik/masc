(** Keeper_event_bus — shared OAS Event_bus reference.

    Holds the shared Event_bus instance set at server bootstrap. Separate
    module to avoid dependency cycles:
    Keeper_keepalive and Keeper_agent_run both depend on keeper
    modules that form cycles if they reference each other.

    The event bus itself is a process-safe message channel and is stored
    in a process-wide [Atomic.t] intentionally.  This is NOT a precedent for
    Eio resources ([Eio.Switch.t], [Eio.Net.t], clocks); those remain
    per-domain via {!Masc_eio_env}.

    @since 2.255.0 *)

let bus_key : Agent_sdk.Event_bus.t option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

let process_bus : Agent_sdk.Event_bus.t option Atomic.t = Atomic.make None

let set bus =
  Domain.DLS.set bus_key (Some bus);
  Atomic.set process_bus (Some bus)

let get () =
  match Domain.DLS.get bus_key with
  | Some _ as bus -> bus
  | None -> Atomic.get process_bus
