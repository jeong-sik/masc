(** A cancellable absolute wall-clock wait. The platform timer uses wall time;
    the clock is rechecked after each timer wake rather than on an interval. *)
val sleep_until : ?on_armed:(unit -> unit) -> float -> unit
(** [on_armed] runs after each platform timer is created, before waiting.
    It must not yield. A later wait can still fail. *)

module For_testing : sig
  val sleep_until_with : now:(unit -> float) -> wait_once:(float -> unit) -> float -> unit
end
