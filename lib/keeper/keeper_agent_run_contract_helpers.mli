(** Pure contract helpers for {!Keeper_agent_run}. *)

val cdal_task_id_for_verdict :
  current_task_id:string option ->
  tool_calls:Keeper_agent_result.tool_call_detail list ->
  string option

val cdal_verdict_persist_decision :
  string option -> [> `Persist_task_scoped of string | `Skip_missing_task_scope ]

val progress_keeper_tool_names_for_contract :
  actual_keeper_tool_names:string list ->
  tool_calls:Keeper_agent_result.tool_call_detail list ->
  string list

val observed_completion_contract_status :
  had_owned_active_task_at_turn_start:bool ->
  actual_keeper_tool_names:string list ->
  response_text_present:bool ->
  Keeper_execution_receipt.completion_contract_result
