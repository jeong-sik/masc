(** MASC runtime boundary for [Agent_sdk.Event_bus].

    This module owns the subscriber queue contract used by keeper/runtime code
    and yields before non-blocking drains so polling loops cannot starve other
    Eio fibers. *)

type handle

val subscribe
  :  capacity:int
  -> overflow:Agent_sdk.Event_bus.overflow
  -> purpose:string
  -> ?filter:Agent_sdk.Event_bus.filter
  -> Agent_sdk.Event_bus.t
  -> handle
(** Subscribe with a subscriber-owned queue contract. Invalid capacities fail
    explicitly before the subscription is installed. *)

val drain : handle -> Agent_sdk.Event_bus.event list
val unsubscribe : Agent_sdk.Event_bus.t -> handle -> unit
val publish : Agent_sdk.Event_bus.t -> Agent_sdk.Event_bus.event -> unit
