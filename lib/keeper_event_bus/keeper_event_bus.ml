(** Keeper_event_bus — OAS Event_bus reference with domain-local override.

    Holds the shared Event_bus instance set at server bootstrap. Separate
    module to avoid dependency cycles:
    Keeper_keepalive and Keeper_agent_run both depend on keeper
    modules that form cycles if they reference each other.

    [Domain.DLS] stores a per-domain override. A process-wide fallback
    preserves the previous lookup contract for domains that have not been
    explicitly initialized.

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
