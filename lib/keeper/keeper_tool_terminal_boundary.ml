let decision = function
  | Keeper_tools_agent_core.Terminal_effect_open -> Ok Runtime_agent.Continue
  | Keeper_tools_agent_core.Deferred_tool_result ->
    Ok (Runtime_agent.Yield Runtime_agent.Durable_stimulus_waiting)
  | Keeper_tools_agent_core.External_effect_deferred ->
    Ok (Runtime_agent.Yield Runtime_agent.External_effect_deferred)
  | Keeper_tools_agent_core.Terminal_effect_completed _ ->
    Ok (Runtime_agent.Yield Runtime_agent.Terminal_tool_completed)
  | Keeper_tools_agent_core.Terminal_effect_failed
      { failure_class; effect_disposition; diagnostic } ->
    Error
      (Keeper_internal_error.core_error_of_masc_internal_error
         (Keeper_internal_error.Terminal_effect_failed
            { failure_class; effect_disposition; diagnostic }))
;;
