(** Turn-scoped OAS event-bus state for [Keeper_unified_turn].

    This module owns the subscription, drain loop, and tool event tracker for a
    single keeper turn. It is intentionally private; [Keeper_unified_turn] keeps
    the public helper surface stable through [Keeper_unified_turn_types]. *)

type t

val create : keeper_name:string -> unit -> t

val drain
  :  ?site:string
  -> t
  -> Keeper_turn_cascade_budget.turn_event_bus_summary

val committed_mutating_tools : t -> string list

val integrity_error : t -> Agent_sdk.Error.sdk_error option

val start_background_drain
  :  clock:float Eio.Time.clock_ty Eio.Resource.t
  -> t
  -> unit

val unsubscribe : t -> unit
