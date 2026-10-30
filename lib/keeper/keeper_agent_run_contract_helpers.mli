(** Pure contract helpers for {!Keeper_agent_run}. *)

val progress_keeper_tool_names_for_contract :
  actual_keeper_tool_names:string list ->
  tool_calls:Keeper_agent_result.tool_call_detail list ->
  string list

val observed_completion_evidence :
  actual_keeper_tool_names:string list ->
  stop_reason:Runtime_agent.stop_reason ->
  response_text_present:bool ->
  Keeper_execution_receipt.completion_contract_result
