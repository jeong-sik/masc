(** Keeper compaction SSE broadcast helper. *)

val broadcast_compaction :
  name:string -> Keeper_post_turn.compaction_recovery -> unit
