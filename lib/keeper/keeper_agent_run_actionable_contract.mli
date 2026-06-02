type analysis =
  { actionable_signal_kind : Keeper_contract_classifier.actionable_signal
  ; actionable_signal_context : Keeper_contract_classifier.actionable_signal_context
  ; violation_reason : string option
  }

(** [true] iff a keeper_stay_silent call in [tool_calls] carries a typed no-work
    proof (a [No_progress] [typed_outcome]). This is the transport-shape read that
    turns the stay_silent handler's embedded proof into the [stay_silent_has_no_work_proof]
    flag the required-tool contract gate consumes. Exposed for regression tests. *)
val stay_silent_no_work_proof_present
  :  Keeper_agent_result.tool_call_detail list
  -> bool

val analyze
  :  world_observation:Keeper_world_observation.world_observation option
  -> allowed_tool_names:string list
  -> turn_affordances:string list
  -> progress_keeper_tool_names:string list
  -> no_progress_success_tool_names:string list
  -> claim_context_allowed:bool
  -> tool_calls:Keeper_agent_result.tool_call_detail list
  -> analysis
