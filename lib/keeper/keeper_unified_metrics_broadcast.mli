(** Keeper lifecycle SSE broadcast helpers. *)

val broadcast_compaction :
  name:string -> Keeper_post_turn.compaction_recovery -> unit

val broadcast_lifecycle_events :
  name:string ->
  handoff_json:Yojson.Safe.t option ->
  unit
