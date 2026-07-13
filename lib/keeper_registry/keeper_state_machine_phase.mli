(** Keeper lifecycle phase variant + bijection helpers. *)

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

val phase_to_string : phase -> string
val phase_of_string : string -> phase option
val all_phases : phase list
