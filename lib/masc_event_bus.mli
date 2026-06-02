(** MASC-owned [Agent_sdk.Event_bus.t] instance.

    Separate bus from the shared OAS Event_bus. MASC domain events
    ([masc.broadcast], [masc.heartbeat], [masc.keeper.lifecycle], ...)
    are published here, not onto OAS's bus. Enforces the OAS boundary
    documented in [event_bus.mli:103-107] — OAS's Event_bus is not a
    general-purpose telemetry channel.

    Process-scoped singleton. [set] is called exactly once at server
    bootstrap; publishers call [get ()] to obtain the bus.

    @since 2.353.0 *)

val set : Agent_sdk.Event_bus.t -> unit
(** Install the MASC Event_bus instance. Called once at server bootstrap. *)

val get : unit -> Agent_sdk.Event_bus.t option
(** [get ()] returns the installed MASC Event_bus, or [None] before
    bootstrap (e.g. in unit tests that skip server bringup). *)
