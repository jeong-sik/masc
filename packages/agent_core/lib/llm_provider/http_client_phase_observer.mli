(** Private fiber-local observation channel for exact-output HTTP effects. *)

type phase =
  | Dispatch_started
  | Response_received of int

val with_observer : (phase -> unit) -> (unit -> 'a) -> 'a
val observe : phase -> unit
