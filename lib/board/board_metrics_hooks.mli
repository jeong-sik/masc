(** Board-owned metric hooks. *)

type observer =
  { observe_persist_lock_acquire_sec : float -> unit
  ; observe_persist_lock_held_sec : float -> unit
  ; inc_dispatch_flusher_start_outcome : unit -> unit
  }

val set_observer : observer -> unit
val observe_persist_lock_acquire_sec : float -> unit
val observe_persist_lock_held_sec : float -> unit
val inc_dispatch_flusher_start_outcome : unit -> unit
