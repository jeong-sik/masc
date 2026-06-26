(** Keeper_event_bus — Per-domain OAS Event_bus reference.

    Holds the shared Event_bus instance set once per OCaml domain at
    server bootstrap.  Separate module to avoid dependency cycles
    between Keeper_keepalive and Keeper_agent_run.

    Stored in [Domain.DLS] to remove the previous module-level
    Atomic global; keeper supervision runs on the owning Eio domain,
    so the observable semantics remain process-scoped.

    @since 2.255.0 *)

(** Install the event bus for the current domain. Call once at bootstrap. *)
val set : Agent_sdk.Event_bus.t -> unit

(** Read the installed event bus for the current domain, if any. *)
val get : unit -> Agent_sdk.Event_bus.t option
