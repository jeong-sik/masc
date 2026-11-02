(** A cancellable absolute wall-clock wait. The platform timer uses wall time;
    the clock is rechecked after each timer wake rather than on an interval. *)
val sleep_until : float -> unit

module For_testing : sig
  val sleep_until_with : now:(unit -> float) -> wait_once:(float -> unit) -> float -> unit
end
