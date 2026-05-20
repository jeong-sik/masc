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
