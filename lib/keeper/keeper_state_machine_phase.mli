(** Keeper lifecycle phase variant + bijection helpers.

    SSOT for the 13-state lifecycle phase enum referenced by the
    [Keeper_state_machine] FSM, dashboard UI, persona audits, and
    operator-facing keeper status surfaces. *)

type phase =
  | Offline
  | Running
  | Failing
  | Overflowed
  | Compacting
  | HandingOff
  | Draining
  | Paused
  | Stopped
  | Crashed
  | Restarting
  | Dead
  | Zombie

val phase_to_string : phase -> string
val phase_of_string : string -> phase option
val all_phases : phase list
