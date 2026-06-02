type analysis =
  { actionable_signal_kind : Keeper_contract_classifier.actionable_signal
  ; actionable_signal_context : Keeper_contract_classifier.actionable_signal_context
  ; violation_reason : string option
  }

val analyze
  :  world_observation:Keeper_world_observation.world_observation option
  -> allowed_tool_names:string list
  -> turn_affordances:string list
  -> progress_keeper_tool_names:string list
  -> no_progress_success_tool_names:string list
  -> claim_context_allowed:bool
  -> analysis
