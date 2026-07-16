(** Keeper lifecycle SSE broadcast helpers. *)

val broadcast_compaction :
  name:string -> Keeper_context_runtime.compaction_recovery -> unit

val broadcast_lifecycle_events :
  name:string ->
  turn_generation:int ->
  handoff_json:Yojson.Safe.t option ->
  unit
