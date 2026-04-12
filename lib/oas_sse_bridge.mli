(** OAS Event_bus → SSE Bridge.

    Subscribes to all OAS Event_bus events, relays them as SSE broadcasts
    to connected dashboard clients, and durably appends the same event stream
    to [.masc/oas-events/].

    @since 2.96.0 *)

(** Start the bridge fiber. Subscribes to [bus], drains events on an
    env-configurable interval
    ([MASC_OAS_SSE_DRAIN_INTERVAL_SEC], default 0.25s),
    broadcasts each as an SSE event, and appends each serializable event to
    the cluster-aware [.masc/oas-events/] store for offline/debug replay.
    Runs as a background Eio fiber under [sw]. *)
val start :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  config:Room.config ->
  bus:Agent_sdk.Event_bus.t ->
  unit
