(** Success-path metric update for a unified keeper cycle. *)

val update_metrics_from_result :
  Keeper_meta_contract.keeper_meta ->
  latency_ms:int ->
  observation:Keeper_world_observation.world_observation ->
  usage_resolution:Keeper_usage_resolution.t ->
  usage_cursor:Keeper_usage_resolution.cursor option ->
  ?is_autonomous_turn:bool ->
  Keeper_agent_run.run_result ->
  Keeper_meta_contract.keeper_meta
