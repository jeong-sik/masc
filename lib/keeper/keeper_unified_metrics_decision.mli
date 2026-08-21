(** Decision-record append for unified keeper cycle metrics. *)

val append_decision_record :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell ->
  observation:Keeper_world_observation.world_observation ->
  latency_ms:int ->
  outcome:string ->
  ?channel:Keeper_world_observation.keeper_cycle_channel ->
  ?turn_mode:Keeper_unified_metrics_support.turn_mode ->
  ?result:Keeper_agent_run.run_result option ->
  ?error:string ->
  ?terminal_reason:Keeper_turn_terminal.t ->
  unit ->
  unit
