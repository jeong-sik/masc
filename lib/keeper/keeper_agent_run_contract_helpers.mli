(** Pure contract helpers for {!Keeper_agent_run}. *)

val cdal_task_id_for_verdict :
  current_task_id:string option ->
  tool_calls:Keeper_agent_result.tool_call_detail list ->
  string option

val cdal_verdict_persist_decision :
  string option -> [> `Persist_task_scoped of string | `Skip_missing_task_scope ]

val progress_keeper_tool_names_for_contract :
  allowed_tool_names:string list ->
  actual_keeper_tool_names:string list ->
  tool_calls:Keeper_agent_result.tool_call_detail list ->
  string list

val no_progress_success_tool_names_for_contract :
  allowed_tool_names:string list ->
  tool_calls:Keeper_agent_result.tool_call_detail list ->
  string list

val completion_contract_violation_error :
  string -> Agent_sdk.Error.sdk_error

val observed_tool_contract_status :
  required_tool_names:string list ->
  missing_visible_required:string list ->
  had_owned_active_task_at_turn_start:bool ->
  actual_keeper_tool_names:string list ->
  Keeper_execution_receipt.tool_contract_result

val passive_violation_contract_status :
  actual_keeper_tool_names:string list ->
  progress_keeper_tool_names:string list ->
  fallback:(unit -> Keeper_execution_receipt.tool_contract_result) ->
  Keeper_execution_receipt.tool_contract_result

val text_only_violation_contract_status :
  actual_keeper_tool_names:string list ->
  fallback:(unit -> Keeper_execution_receipt.tool_contract_result) ->
  Keeper_execution_receipt.tool_contract_result
