(** Compatibility wrapper around [Agent_sdk.Event_bus].

    Keeper/runtime code uses this module as the local Event_bus boundary.  The
    wrapper keeps lightweight MASC-side observability for publish counts and
    per-purpose subscriber depth while the SDK bus owns queueing semantics. *)

type handle

val subscribe
  :  purpose:string
  -> ?filter:Agent_sdk.Event_bus.filter
  -> Agent_sdk.Event_bus.t
  -> handle

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
