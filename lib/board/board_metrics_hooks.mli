(** Board-owned metric hooks with typed label dimensions. *)

type board_persist_surface =
  | Board_post_meta_json

type runtime_actor =
  | Flusher
  | Routing_retry

type runtime_actor_start_outcome =
  | Started
  | Start_failed

type observer =
  { observe_persist_lock_acquire_sec : float -> unit
  ; observe_persist_lock_held_sec : float -> unit
  ; inc_runtime_actor_start_outcome :
      actor:runtime_actor -> outcome:runtime_actor_start_outcome -> unit
  ; inc_persistence_read_drop :
      surface:board_persist_surface -> reason:Read_drop_reason.t -> unit
  }

val set_observer : observer -> unit
val observe_persist_lock_acquire_sec : float -> unit
val observe_persist_lock_held_sec : float -> unit
val inc_runtime_actor_start_outcome :
  actor:runtime_actor -> outcome:runtime_actor_start_outcome -> unit
val inc_persistence_read_drop :
  surface:board_persist_surface -> reason:Read_drop_reason.t -> unit
