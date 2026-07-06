(** Board-owned metric hooks with typed label dimensions. *)

type board_persist_surface =
  | Board_post_meta_json
  | Board_post_kind
  | Board_post_mention_ids
  | Board_comment_mention_ids
  | Board_sub_board_member_ids

type flusher_outcome =
  | Switch_finished
  | Cas_exhausted

type observer =
  { observe_persist_lock_acquire_sec : float -> unit
  ; observe_persist_lock_held_sec : float -> unit
  ; inc_dispatch_flusher_start_outcome : outcome:flusher_outcome -> unit
  ; inc_vote_fixture_detected : count:int -> unit
  ; inc_persistence_read_drop :
      surface:board_persist_surface -> reason:Read_drop_reason.t -> unit
  }

val set_observer : observer -> unit
val observe_persist_lock_acquire_sec : float -> unit
val observe_persist_lock_held_sec : float -> unit
val inc_dispatch_flusher_start_outcome : outcome:flusher_outcome -> unit
val inc_vote_fixture_detected : count:int -> unit
val inc_persistence_read_drop :
  surface:board_persist_surface -> reason:Read_drop_reason.t -> unit
