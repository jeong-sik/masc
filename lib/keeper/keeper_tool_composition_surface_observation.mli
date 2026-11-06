(** What a composition writes to the tool-call log, and the result of an
    execution.

    [observe_node_result] records the row of one node's result and returns
    [Error] when the receipt of a retained result could not be committed.
    [observe_composition_run_summary] records the row that closes a run, and
    [observe_async_run_settlement] records it for an asynchronous run once its
    request reaches a durable terminal status. [result_of_execution] turns the
    node results of an execution, or its failure, into the tool result.
    [Keeper_tool_composition_surface] includes this module. *)
val observe_node_result :
  ?on_receipt_committed:(Ids.Execution_id.t -> unit) ->
  composition_tool:string ->
  composition_execution:Keeper_tool_composition_catalog.execution_mode ->
  composition_tool_kind:Keeper_tool_descriptor.tool_kind ->
  composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  parent_invocation:Agent_core_base.Tool_contract.Invocation.t ->
  meta:Keeper_meta_contract.keeper_meta ->
  turn_context:Keeper_tool_call_log_context.turn_context ->
  Keeper_tool_plan_executor.node_result -> (unit, string) result

val observe_composition_run_summary :
  composition_tool:string ->
  ?skill_reference:Skill_reference.t ->
  composition_execution:Keeper_tool_composition_catalog.execution_mode ->
  composition_tool_kind:Keeper_tool_descriptor.tool_kind ->
  composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  parent_invocation:Agent_core_base.Tool_contract.Invocation.t ->
  meta:Keeper_meta_contract.keeper_meta ->
  turn_context:Keeper_tool_call_log_context.turn_context option ->
  input:Yojson.Safe.t ->
  output_text:string ->
  success:bool ->
  duration_ms:float -> ?typed_result:Tool_result.result -> unit -> unit

val observe_async_run_settlement :
  composition_tool:string ->
  ?skill_reference:Skill_reference.t ->
  composition_tool_kind:Keeper_tool_descriptor.tool_kind ->
  composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  parent_invocation:Agent_core_base.Tool_contract.Invocation.t ->
  meta:Keeper_meta_contract.keeper_meta ->
  turn_context:Keeper_tool_call_log_context.turn_context option ->
  Keeper_msg_async.worker_settlement -> unit

val result_of_execution :
  tool_name:string ->
  tool_kind:Keeper_tool_descriptor.tool_kind ->
  start_time:Tool_timing.started ->
  (Keeper_tool_plan_executor.node_result list, Keeper_tool_plan_executor.failure) result -> Tool_result.result
