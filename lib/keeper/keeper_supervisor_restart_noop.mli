(** Test-only restart launch noop state. *)

val set : bool -> unit
val enabled : unit -> bool
val with_noop : (unit -> 'a) -> 'a
