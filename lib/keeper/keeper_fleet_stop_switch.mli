(** Compatibility facade for the fleet stop switch.

    The authoritative state lives in {!Keeper_turn_admission}. *)

type fleet_state = Keeper_turn_admission.fleet_state =
  | Running
  | Paused
  | Stopped

type admission_error = Keeper_turn_admission.rejection =
  | Fleet_paused
  | Fleet_stopped
  | Global_inflight_exceeded

type snapshot =
  { fleet_state : fleet_state
  ; global_inflight : int
  }

val fleet_state_to_string : fleet_state -> string
val admission_error_to_string : admission_error -> string
val snapshot : unit -> snapshot
val pause_fleet : unit -> unit
val resume_fleet : unit -> unit
val stop_fleet : unit -> unit
val acquire_turn : limit:int -> (unit, admission_error) result
val release_turn : unit -> unit
val available_turns : limit:int -> int
val reset_for_test : unit -> unit
