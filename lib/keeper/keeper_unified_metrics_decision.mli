(** Decision-record append for unified keeper cycle metrics. *)

val append_decision_record :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  latency_ms:int ->
  ?semaphore_wait_ms:int ->
  outcome:string ->
  ?degraded_retry_applied:bool ->
  ?degraded_retry_cascade:string ->
  ?fallback_reason:string ->
  ?turn_mode:Keeper_unified_metrics_support.turn_mode ->
  ?social_state:Keeper_social_model.social_state ->
  ?deliberation_execution:Keeper_deliberation.execution_result ->
  ?result:Keeper_agent_run.run_result option ->
  ?error:string ->
  ?terminal_reason:Keeper_turn_terminal.t ->
  unit ->
  unit
