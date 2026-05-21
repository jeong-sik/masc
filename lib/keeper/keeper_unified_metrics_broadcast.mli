(** Keeper lifecycle SSE broadcast helpers. *)

val broadcast_lifecycle_events
  :  name:string
  -> turn_generation:int
  -> compaction:Keeper_exec_context.compaction_event
  -> handoff_json:Yojson.Safe.t option
  -> unit
