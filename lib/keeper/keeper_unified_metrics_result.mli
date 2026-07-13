(** Success-path metric update for a unified keeper cycle. *)

val update_metrics_from_result :
  Keeper_meta_contract.keeper_meta ->
  latency_ms:int ->
  observation:Keeper_world_observation.world_observation ->
  ?is_autonomous_turn:bool ->
  ?update_proactive_rt:bool ->
  Keeper_agent_run.run_result ->
  Keeper_meta_contract.keeper_meta
