(** Board-owned metric hooks.

    The persist-lock samples are measured inside [persist_mutex] and reported
    after it is released, so an observer may call back into Board. *)

type observer =
  { observe_persist_lock_acquire_sec : float -> unit
  ; observe_persist_lock_held_sec : float -> unit
  ; inc_dispatch_flusher_start_outcome : unit -> unit
  }

val set_observer : observer -> unit
val observe_persist_lock_acquire_sec : float -> unit
val observe_persist_lock_held_sec : float -> unit
val inc_dispatch_flusher_start_outcome : unit -> unit
