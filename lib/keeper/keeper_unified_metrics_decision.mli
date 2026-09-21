(** Decision-record append for unified keeper cycle metrics. *)

(** Which execution path produced a decision-record row.

    The two paths write the same record and, before #37376, disagreed about the
    same turn. Splitting them was only possible by accident: direct always
    passed [~fallback_reason:None], so a row with an applied lane and no reason
    was direct. That field is gone now, and nothing else told them apart —
    [channel] folds [Direct] into [Reactive], which serialises to the same
    ["turn"] the autonomous cycle writes, and no other column has disjoint
    values between the two.

    Closed and payload-free on purpose. It answers one question, and a string
    here would become somewhere to write something else. *)
type execution_path =
  | Direct_turn
  | Autonomous_cycle

val execution_path_to_string : execution_path -> string

val append_decision_record :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell ->
  observation:Keeper_world_observation.world_observation ->
  latency_ms:int ->
  outcome:string ->
  ?channel:Keeper_world_observation.keeper_cycle_channel ->
  execution_path:execution_path ->
  degraded_retry_applied:Keeper_error_classify.degraded_retry option ->
  degraded_retry_deferred:Keeper_error_classify.degraded_retry option ->
  ?turn_mode:Keeper_unified_metrics_support.turn_mode ->
  ?result:Keeper_agent_run.run_result option ->
  ?usage_resolution:Keeper_usage_resolution.t option ->
  ?error:string ->
  ?terminal_reason:Keeper_turn_terminal.t ->
  ?executed_runtime_id:string ->
  unit ->
  unit
