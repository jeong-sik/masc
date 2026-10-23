(** AGENT_CORE Event_bus → SSE Bridge.

    Subscribes to all AGENT_CORE Event_bus events, relays them as SSE broadcasts
    to connected dashboard clients, and appends the events this subscriber
    observes to [.masc/agent-core-events/]. The store is not a complete bus replay.

    @since 2.96.0 *)

(** Start the bridge fiber. Subscribes to [bus], drains events on an
    env-configurable interval
    ([MASC_AGENT_CORE_SSE_DRAIN_INTERVAL_SEC], default 0.25s),
    broadcasts each as an SSE event, and appends each observed serializable
    event to the [.masc/agent-core-events/] store for offline/debugging.
    The server's prune pass removes the store's day files by age.
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

(** The [event_type] a Custom event named [name] carries on the SSE wire: a
    [masc.*] name with every dot turned into [:], any other name unchanged. A
    reader that recognises a MASC Custom event matches against this, not a
    copy of the rule. *)
val public_custom_event_type : string -> string

(** Serialize a single AGENT_CORE event to SSE JSON.
    Exposed for unit testing. *)
val native_event_to_json : Agent_core.Event_bus.event -> Yojson.Safe.t option

module For_testing : sig
  val emit_native_event_log : Agent_core.Event_bus.event -> Yojson.Safe.t -> unit
  (** The production log projection. The envelope owns the Keeper turn;
      the payload owns the agent. Session-local ordinals are never substituted. *)
end
