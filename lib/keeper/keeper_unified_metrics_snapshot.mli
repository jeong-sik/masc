(** Metrics snapshot append for the unified keeper cycle. *)

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
  compaction:Keeper_exec_context.compaction_event ->
  handoff_json:Yojson.Safe.t option ->
  ?timeout_budget_json:Yojson.Safe.t ->
  ?deliberation_execution:Keeper_deliberation.execution_result ->
  unit ->
  unit
