(** Metrics snapshot append helper for unified keeper cycles. *)

val append_metrics_snapshot :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  result:Keeper_agent_run.run_result ->
  latency_ms:int ->
  turn_cost:float ->
  turn_generation:int ->
  channel:string ->
  snapshot_source:string ->
  context_ratio:float ->
  context_tokens:int ->
  context_max:int ->
  message_count:int ->
  compaction:Keeper_context_runtime.compaction_event ->
  handoff_json:Yojson.Safe.t option ->
  ?provider_timeout_plan_json:Yojson.Safe.t ->
  ?deliberation_execution:Keeper_deliberation.execution_result ->
  unit ->
  unit
