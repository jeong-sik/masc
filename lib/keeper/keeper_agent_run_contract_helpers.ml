let keeper_tool_names_for_outcome ~(tool_calls : Keeper_agent_result.tool_call_detail list)
      ~(outcome : Tool_result.tool_call_outcome)
  : string list
  =
  tool_calls
  |> List.rev
  |> List.filter_map (fun (detail : Keeper_agent_result.tool_call_detail) ->
    if detail.execution_outcome = outcome
    then Some (Keeper_tool_descriptor_resolution.canonical_tool_name detail.tool_name)
    else None)
;;

let progress_keeper_tool_names_for_contract
      ~(actual_keeper_tool_names : string list)
      ~(tool_calls : Keeper_agent_result.tool_call_detail list)
  : string list
  =
  match tool_calls with
  | [] -> actual_keeper_tool_names
  | _ :: _ -> keeper_tool_names_for_outcome ~tool_calls ~outcome:Tool_result.Ok
;;

let observed_completion_evidence
      ~actual_keeper_tool_names
      ~stop_reason ~response_text_present
  : Keeper_execution_receipt.completion_contract_result
  =
  match stop_reason with
  | Runtime_agent.InputRequired _
  | Runtime_agent.Yielded_to_operation_queued _
  | Runtime_agent.Yielded_to_durable_stimulus _
  | Runtime_agent.Yielded_after_repeated_tool_call _
  | Runtime_agent.Yielded_after_repeated_assistant_text _ ->
    Keeper_execution_receipt.Completion_observation_unknown
  | Runtime_agent.Completed ->
    if actual_keeper_tool_names <> []
    then Keeper_execution_receipt.Completion_tool_execution_observed
    else if response_text_present
    then Keeper_execution_receipt.Completion_response_observed
    else Keeper_execution_receipt.Completion_no_visible_output
;;
