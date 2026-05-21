(** Success-path unified keeper metric update. *)

val update_metrics_from_result :
  Keeper_types.keeper_meta ->
  latency_ms:int ->
  observation:Keeper_world_observation.world_observation ->
  ?is_autonomous_turn:bool ->
  ?update_proactive_rt:bool ->
  ?social_state:Keeper_social_model.social_state ->
  ?social_transition_reason:string ->
  ?context_max:int ->
  Keeper_agent_run.run_result ->
  Keeper_types.keeper_meta
