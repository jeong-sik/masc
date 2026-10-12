let normalize_response_text_for_finalization
      ~runtime_id
      ~(run_result : Runtime_agent.run_result)
      ~text
      ~tool_names
      ()
  =
  match run_result.stop_reason with
  | Runtime_agent.Yielded_to_operation_queued _
  | Runtime_agent.Yielded_to_durable_stimulus _
  | Runtime_agent.Yielded_after_repeated_tool_call _
  | Runtime_agent.Yielded_after_repeated_assistant_text _
  | Runtime_agent.Completed
  | Runtime_agent.InputRequired _ ->
  if
    Keeper_agent_run_response_text.stop_reason_suppresses_visible_response
      run_result.stop_reason
  then Ok ""
  else
    match Keeper_tooling.Response.normalize_response_text ~text ~tool_names () with
  | Ok response_text -> Ok response_text
  | Error _ ->
    (* Finalization exposes the typed accept-rejected response itself. Tool
       execution history stays in the AGENT_CORE checkpoint; it is not projected into
       a read/mutating behavioral classification. *)
    Error
      (Keeper_turn_driver_try_provider.accept_rejected_error
         ~runtime_id
         ~response:run_result.response)
;;
