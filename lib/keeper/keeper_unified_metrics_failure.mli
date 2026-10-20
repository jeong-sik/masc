(** Failure-path metric update for a unified keeper cycle. *)

val update_metrics_from_failure :
  Keeper_meta_contract.keeper_meta ->
  latency_ms:int ->
  observation:Keeper_world_observation.world_observation ->
  reason:string ->
  ?core_error:Agent_core.Error.t ->
  unit ->
  Keeper_meta_contract.keeper_meta

(** Adds resolved attempt token deltas and advances the usage cursor. Cost
    coverage is accumulated once from all actual readings by the terminal
    commit path, including attempts without readings. *)
val with_attempt_spend :
  Keeper_meta_contract.keeper_meta ->
  resolved:Keeper_turn_spend.resolved list ->
  usage_cursor:Keeper_usage_resolution.cursor option ->
  Keeper_meta_contract.keeper_meta
