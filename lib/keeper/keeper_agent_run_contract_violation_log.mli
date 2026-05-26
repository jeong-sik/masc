val record_passive
  :  keeper_name:string
  -> has_current_task:bool
  -> contract_status:Keeper_execution_receipt.tool_contract_result
  -> actionable_signal_kind:Keeper_contract_classifier.actionable_signal
  -> turns:int
  -> actual_keeper_tool_names:string list
  -> reason:string
  -> unit

val record_text_only
  :  keeper_name:string
  -> has_current_task:bool
  -> contract_status:Keeper_execution_receipt.tool_contract_result
  -> effective_completion_contract:Keeper_tool_completion_contract.completion_contract
  -> actionable_signal_kind:Keeper_contract_classifier.actionable_signal
  -> turns:int
  -> actual_keeper_tool_names:string list
  -> reason:string
  -> unit
