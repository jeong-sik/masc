(** Keeper outcome rollups for the dashboard. *)

val compute_outcomes_rollup :
  keeper_name:string ->
  agent_name:string ->
  recent_crash_count:int ->
  registry_entry:Keeper_registry.registry_entry option ->
  Yojson.Safe.t
