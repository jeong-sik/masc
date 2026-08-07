(** OAS Event_bus → SSE Bridge.

    Subscribes to all OAS Event_bus events, relays them as SSE broadcasts
    to connected dashboard clients, and appends the events this subscriber
    observes to [.masc/oas-events/]. The store is not a complete bus replay.

    @since 2.96.0 *)

(** Start the bridge fiber. Subscribes to [bus], drains events on an
    env-configurable interval
    ([MASC_OAS_SSE_DRAIN_INTERVAL_SEC], default 0.25s),
    broadcasts each as an SSE event, and appends each observed serializable
    event to the cluster-aware [.masc/oas-events/] store for offline/debugging.
    The durable store prunes old date-split files on append using
    [MASC_OAS_EVENTS_RETENTION_DAYS] (default 30; non-positive disables).
    Runs as a background Eio fiber under [sw]. *)
val start :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  config:Workspace.config ->
  bus:Agent_sdk.Event_bus.t ->
  unit

val start_with_interval :
  drain_interval_s:float ->
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  config:Workspace.config ->
  bus:Agent_sdk.Event_bus.t ->
  unit
(** Start the bridge fiber with an explicit drain interval.
    Test-only surface — production uses [start] which reads
    [MASC_OAS_SSE_DRAIN_INTERVAL_SEC] from the environment. *)

(** Serialize a single OAS event to SSE JSON.
    Exposed for unit testing. *)
val native_event_to_json : Agent_sdk.Event_bus.event -> Yojson.Safe.t option

