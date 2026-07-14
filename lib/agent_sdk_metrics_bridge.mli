(** Compatibility wrapper around [Agent_sdk.Event_bus].

    Otel_metric_store instrumentation was retired from this module.  The wrapper
    remains because keeper/runtime code uses it as the local Event_bus
    boundary. *)

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

val start_sampler
  :  sw:Eio.Switch.t
  -> clock:[> float Eio.Time.clock_ty ] Eio.Std.r
  -> ?interval_s:float
  -> ?warn_threshold:int
  -> unit
  -> unit

module For_testing : sig
  type transition =
    [ `Warn of string * int
    | `Recovered of string * int
    ]

  val current_depth : purpose:string -> int
  val sample_threshold_transitions : warn_threshold:int -> transition list
  val reset : unit -> unit
end
