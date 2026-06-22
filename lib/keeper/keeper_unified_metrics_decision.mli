(** Decision-record append for unified keeper cycle metrics. *)

val append_decision_record :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell ->
  observation:Keeper_world_observation.world_observation ->
  latency_ms:int ->
  outcome:string ->
  ?degraded_retry_applied:bool ->
  ?degraded_retry_runtime:string ->
  ?fallback_reason:string ->
  ?turn_mode:Keeper_unified_metrics_support.turn_mode ->
  ?deliberation_execution:Keeper_deliberation.execution_result ->
  ?result:Keeper_agent_run.run_result option ->
  ?error:string ->
  ?terminal_reason:Keeper_turn_terminal.t ->
  unit ->
  unit
