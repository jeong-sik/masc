(** Compatibility wrapper around [Agent_sdk.Event_bus].

    Otel_metric_store instrumentation was retired from this module.  The wrapper
    remains because keeper/runtime code uses it as the local Event_bus
    boundary. *)

type handle

val subscribe
  :  purpose:string
  -> ?filter:Agent_sdk.Event_bus.filter
  -> Agent_sdk.Event_bus.t
  -> handle

val drain : handle -> Agent_sdk.Event_bus.event list
val unsubscribe : Agent_sdk.Event_bus.t -> handle -> unit
val publish : Agent_sdk.Event_bus.t -> Agent_sdk.Event_bus.event -> unit
