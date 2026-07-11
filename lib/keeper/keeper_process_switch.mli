(** Process-lifetime Keeper orchestration switch SSOT. *)

val set : Eio.Switch.t -> unit
val get : unit -> Eio.Switch.t option
