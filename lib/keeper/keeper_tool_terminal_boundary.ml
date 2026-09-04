let decision = function
  | Keeper_tools_agent_core.Terminal_effect_open -> Ok Runtime_agent.Continue
  | Keeper_tools_agent_core.Deferred_tool_result ->
    Ok (Runtime_agent.Yield Runtime_agent.Durable_stimulus_waiting)
  (* A Gate deferral parks one call; it neither completes an effect nor gives
     the turn something to wait on. The deferred payload tells the Keeper to
     continue other work, and ending the turn here contradicted that payload:
     the operator got a turn that parked a call and then stopped, with the
     model's own words for that turn arriving as a bare status line. The
     parked call is replayed by the host when the approval resolves
     (Keeper_tools_agent_core_bundle), and a model that re-issues the
     identical call is stopped by the repeated-tool-call yield, so the turn
     needs no boundary here. *)
  | Keeper_tools_agent_core.External_effect_deferred -> Ok Runtime_agent.Continue
  | Keeper_tools_agent_core.Terminal_effect_completed _ ->
    Ok (Runtime_agent.Yield Runtime_agent.Terminal_tool_completed)
  | Keeper_tools_agent_core.Terminal_effect_failed
      { failure_class; effect_disposition; diagnostic } ->
    Error
      (Keeper_internal_error.core_error_of_masc_internal_error
         (Keeper_internal_error.Terminal_effect_failed
            { failure_class; effect_disposition; diagnostic }))
;;
