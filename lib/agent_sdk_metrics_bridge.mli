(** MASC subscription boundary over [Agent_sdk.Event_bus].

    Every subscription must present a closed, MASC-owned resource contract.
    Runtime queue statistics are exported directly from
    [Agent_sdk.Event_bus.stats] by [Otel_runtime_observables]. *)

type handle

val subscribe
  :  contract:Masc_event_bus_subscription.t
  -> ?filter:Agent_sdk.Event_bus.filter
  -> Agent_sdk.Event_bus.t
  -> handle

val drain : handle -> Agent_sdk.Event_bus.event list
val unsubscribe : Agent_sdk.Event_bus.t -> handle -> unit
val publish : Agent_sdk.Event_bus.t -> Agent_sdk.Event_bus.event -> unit
