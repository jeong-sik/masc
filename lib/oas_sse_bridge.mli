(** OAS Event_bus → SSE Bridge.

    Subscribes to all [masc:*] events on the OAS Event_bus
    and relays them as SSE broadcasts to connected dashboard clients.

    @since 2.96.0 *)

(** Start the bridge fiber. Subscribes to [bus] with a [masc:] prefix filter,
    drains events on an env-configurable interval
    ([MASC_OAS_SSE_DRAIN_INTERVAL_SEC], default 0.25s),
    and broadcasts each as an SSE event.
    Runs as a background Eio fiber under [sw]. *)
val start : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> bus:Agent_sdk.Event_bus.t -> unit
