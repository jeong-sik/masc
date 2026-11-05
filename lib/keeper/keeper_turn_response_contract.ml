let normalize_response_text_for_finalization
      ~(run_result : Runtime_agent.run_result)
      ~text
  =
  if
    Keeper_agent_run_response_text.stop_reason_suppresses_visible_response
      run_result.stop_reason
    || String.trim text = ""
  then ""
  else text
;;
