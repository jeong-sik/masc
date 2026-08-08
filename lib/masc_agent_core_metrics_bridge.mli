(** Compatibility wrapper around [Masc_agent_core.Event_bus].

    Otel_metric_store instrumentation was retired from this module.  The wrapper
    remains because keeper/runtime code uses it as the local Event_bus
    boundary. *)

type handle

val subscribe
  :  capacity:int
  -> overflow:Masc_agent_core.Event_bus.overflow
  -> purpose:string
  -> ?filter:Masc_agent_core.Event_bus.filter
  -> Masc_agent_core.Event_bus.t
  -> handle
(** Subscribe with a subscriber-owned queue contract. Invalid capacities fail
    explicitly before the subscription is installed. *)

val drain : handle -> Masc_agent_core.Event_bus.event list
val unsubscribe : Masc_agent_core.Event_bus.t -> handle -> unit
val publish : Masc_agent_core.Event_bus.t -> Masc_agent_core.Event_bus.event -> unit
