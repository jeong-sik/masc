(** Event_bus_slots — process-wide holders for the two
    [Agent_sdk.Event_bus.t] instances masc keeps at server bootstrap.

    masc uses two distinct buses with deliberately different storage
    policies; both live here so the holder story is in one place and
    keeper modules avoid dependency cycles (Keeper_keepalive and
    Keeper_agent_run would form cycles if they referenced each other).

    {b masc slot} — MASC-owned bus for MASC domain events (broadcasts,
    heartbeats, task transitions, keeper lifecycle, etc.).  MASC
    publishes on its own bus rather than onto OAS's shared Event_bus.
    OAS's [event_bus.mli:103-107] says: "External publishers should use
    their own Event_bus.t instance for domain-specific events rather
    than publishing onto OAS's bus.  Treating OAS's Event_bus as a
    general-purpose telemetry channel creates cross-layer coupling."
    Process-scoped [Atomic.t] singleton: set once at server bootstrap,
    read from publishers throughout the process.

    {b keeper slot} — reference to the shared OAS Event_bus.  The
    current domain's [Domain.DLS] value is preferred; a process-wide
    fallback preserves legacy lookup semantics for domains that have
    not installed their own bus yet.  The event bus itself is a
    process-safe message channel and is stored process-wide
    intentionally.  This is NOT a precedent for Eio resources
    ([Eio.Switch.t], [Eio.Net.t], clocks); those remain per-domain via
    {!Masc_eio_env}.

    Both slots hold the same type, [Agent_sdk.Event_bus.t] — we re-use
    the library rather than re-inventing the transport.  Different
    instances, different subscribers, different lifecycles.

    @since 2.353.0 (as [Masc_event_bus] / [Keeper_event_bus]; merged
           into one module with two named slots) *)

(* masc slot — process-wide Atomic policy.  Do not merge this storage
   with the keeper slot: the DLS-vs-Atomic difference is semantic, not
   stylistic. *)
let masc_bus_ref : Agent_sdk.Event_bus.t option Atomic.t = Atomic.make None

let set_masc bus = Atomic.set masc_bus_ref (Some bus)
let get_masc () = Atomic.get masc_bus_ref

(* keeper slot — domain-local preference with process fallback. *)
let keeper_bus_key : Agent_sdk.Event_bus.t option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

let keeper_process_bus : Agent_sdk.Event_bus.t option Atomic.t =
  Atomic.make None

let set_keeper bus =
  Domain.DLS.set keeper_bus_key (Some bus);
  Atomic.set keeper_process_bus (Some bus)

let get_keeper () =
  match Domain.DLS.get keeper_bus_key with
  | Some _ as bus -> bus
  | None -> Atomic.get keeper_process_bus
