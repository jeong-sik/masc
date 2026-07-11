(** Process-lifetime Keeper orchestration switch SSOT. *)

val set : Eio.Switch.t -> unit
val get : unit -> Eio.Switch.t option

module For_testing : sig
  val clear : unit -> unit
  (** Remove the process switch between isolated test cases. Only safe when
      every worker attached to the prior switch has joined. *)
end
