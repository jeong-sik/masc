(** MASC runtime boundary for [Agent_core.Event_bus].

    This module owns the subscriber queue contract used by keeper/runtime code
    and yields before non-blocking drains so polling loops cannot starve other
    Eio fibers. *)

type handle

val subscribe
  :  capacity:int
  -> overflow:Agent_core.Event_bus.overflow
  -> purpose:string
  -> ?filter:Agent_core.Event_bus.filter
  -> Agent_core.Event_bus.t
  -> handle
(** Subscribe with a subscriber-owned queue contract. Invalid capacities fail
    explicitly before the subscription is installed. *)

val drain : handle -> Agent_core.Event_bus.event list

(** Events the subscription's overflow policy discarded since the previous
    {!drain_reporting_drops} on the same handle. *)
type overflow_loss =
  | Nothing_dropped
  | Dropped of int
  (** This many events passed the subscription's filter and were discarded
      before this drain returned. Which events they were is not known. *)

type batch =
  { events : Agent_core.Event_bus.event list
  ; overflow_loss : overflow_loss
  }

val drain_reporting_drops : handle -> batch
(** [drain], plus whether events were lost to the overflow policy. The drop
    counter is read after the drain, so every drop it reports belongs to an
    event published before this call returned, and a consumer that reacts to
    [Dropped] after this call covers it. The last reported count lives in the
    handle and is claimed with a compare-and-set, so concurrent drains of one
    handle split the drops between them and no drop is reported twice. *)

val unsubscribe : Agent_core.Event_bus.t -> handle -> unit
val publish : Agent_core.Event_bus.t -> Agent_core.Event_bus.event -> unit
