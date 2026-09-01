(** AGENT_CORE Event_bus → SSE Bridge.

    Subscribes to all AGENT_CORE Event_bus events, relays them as SSE broadcasts
    to connected dashboard clients, and appends the events this subscriber
    observes to [.masc/agent-core-events/]. The store is not a complete bus replay.

    @since 2.96.0 *)

(** Start the bridge fiber. Subscribes to [bus], drains events on an
    env-configurable interval
    ([MASC_AGENT_CORE_SSE_DRAIN_INTERVAL_SEC], default 0.25s),
    broadcasts each as an SSE event, and appends each observed serializable
    event to the cluster-aware [.masc/agent-core-events/] store for offline/debugging.
    The durable store prunes old date-split files on append using
    [MASC_AGENT_CORE_EVENTS_RETENTION_DAYS] (default 30; non-positive disables).
    Runs as a background Eio fiber under [sw].

    Contract: the bridge fiber is a never-ending loop forked on [sw].
    [sw] must be ended by cancellation (e.g. server shutdown), never by
    drain — a caller that returns normally from [Switch.run] with this
    fiber forked will hang. *)
val start :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  config:Workspace.config ->
  bus:Agent_core.Event_bus.t ->
  unit

(** Serialize a single AGENT_CORE event to SSE JSON.
    Exposed for unit testing. *)
val native_event_to_json : Agent_core.Event_bus.event -> Yojson.Safe.t option
