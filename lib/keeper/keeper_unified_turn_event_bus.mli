(** Turn-scoped OAS event-bus state for [Keeper_unified_turn].

    This module owns the subscription, drain loop, and tool event tracker for a
    single keeper turn. It is intentionally private; [Keeper_unified_turn] keeps
    the public helper surface stable through [Keeper_unified_turn_types]. *)

type t

val create : keeper_name:string -> turn_id:int -> unit -> t

val drain
  :  ?site:string
  -> t
  -> Keeper_turn_runtime_budget.turn_event_bus_summary

val committed_mutating_tools : t -> string list

val integrity_error : t -> Agent_sdk.Error.sdk_error option

val start_background_drain
  :  clock:float Eio.Time.clock_ty Eio.Resource.t
  -> t
  -> unit

val unsubscribe : t -> unit

module For_testing : sig
  type fsm_transition =
    | Enter_awaiting
    | Leave_awaiting

  type event_bus_state =
    { summary : Keeper_turn_runtime_budget.turn_event_bus_summary
    ; tracker : Keeper_unified_turn_types.turn_tool_event_tracker
    ; pending_tool_count : int
    }

  type drain_cancel_state =
    | Inactive
    | Active of Eio.Cancel.t
    | Closed

  val record_fsm_tool_transitions
    :  keeper_name:string
    -> turn_id:int
    -> int
    -> Agent_sdk.Event_bus.event list
    -> int * fsm_transition list

  (** Test-only read accessor. *)
  val get_state : t -> event_bus_state

  (** Test-only read accessor. *)
  val get_drain_cancel : t -> drain_cancel_state

  (** Test-only write accessor. No production caller. *)
  val set_drain_cancel : t -> drain_cancel_state -> unit

  (** Test-only write accessor. No production caller. *)
  val exchange_drain_cancel : t -> drain_cancel_state -> drain_cancel_state

  (** The take-and-close step [unsubscribe] runs: atomically claims [Closed]
      and returns the displaced background drain handle (if any). *)
  val take_drain_cancel : t -> Eio.Cancel.t option
end
