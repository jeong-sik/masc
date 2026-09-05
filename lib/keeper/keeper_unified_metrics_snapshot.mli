(** Metrics snapshot append helper for unified keeper cycles. *)

val append_metrics_snapshot :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  result:Keeper_agent_run.run_result ->
  latency_ms:int ->
  usage_resolution:Keeper_usage_resolution.t ->
  turn_cost:float ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  checkpoint_bytes:int option ->
  message_count:int ->
  unit ->
  unit
