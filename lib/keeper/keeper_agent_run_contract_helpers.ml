let cdal_task_id_for_verdict ~(current_task_id : string option)
      ~(tool_calls : Keeper_agent_result.tool_call_detail list)
  =
  match current_task_id with
  | Some task_id -> Some task_id
  | None ->
    List.find_map
      (fun (detail : Keeper_agent_result.tool_call_detail) ->
         match detail.task_id with
         | Some task_id when String.trim task_id <> "" -> Some task_id
         | _ -> None)
      tool_calls
;;

let cdal_verdict_persist_decision = function
  | Some task_id when String.trim task_id <> "" -> `Persist_task_scoped task_id
  | _ -> `Skip_missing_task_scope
;;

let keeper_tool_names_for_outcome ~(tool_calls : Keeper_agent_result.tool_call_detail list)
      ~(outcome : string)
  : string list
  =
  tool_calls
  |> List.rev
  |> List.filter_map (fun (detail : Keeper_agent_result.tool_call_detail) ->
    if String.equal detail.outcome outcome
    then Some (Keeper_tool_resolution.canonical_tool_name detail.tool_name)
    else None)
;;

let progress_keeper_tool_names_for_contract
      ~(actual_keeper_tool_names : string list)
      ~(tool_calls : Keeper_agent_result.tool_call_detail list)
  : string list
  =
  match tool_calls with
  | [] -> actual_keeper_tool_names
  | _ :: _ -> keeper_tool_names_for_outcome ~tool_calls ~outcome:"ok"
;;

let visible_response_text_present ~stop_reason ~response_text_present =
  match stop_reason with
  | Runtime_agent.TurnBudgetExhausted _ -> false
  | Runtime_agent.Completed | Runtime_agent.MutationBoundaryReached _ ->
    response_text_present
;;

let budget_exhausted_contract_status ~stop_reason status =
  match stop_reason, status with
  | ( Runtime_agent.TurnBudgetExhausted _
    , Keeper_execution_receipt.Contract_satisfied_execution ) ->
    Keeper_execution_receipt.Contract_needs_execution_progress
  | (Runtime_agent.Completed | Runtime_agent.MutationBoundaryReached _), _
  | Runtime_agent.TurnBudgetExhausted _, _ ->
    status
;;

let observed_completion_contract_status
      ~had_owned_active_task_at_turn_start ~actual_keeper_tool_names
      ~stop_reason ~response_text_present
  : Keeper_execution_receipt.completion_contract_result
  =
  let response_text_present =
    visible_response_text_present ~stop_reason ~response_text_present
  in
  let status =
    if (not response_text_present) && actual_keeper_tool_names = []
    then Keeper_execution_receipt.Contract_violated
    else
      Keeper_agent_run_turn_helpers.completion_contract_result_for_progress_evidence
        ~had_owned_active_task_at_turn_start
        ~actual_keeper_tool_names
  in
  budget_exhausted_contract_status ~stop_reason status
;;

let text_only_violation_contract_status ~actual_keeper_tool_names ~fallback
  : Keeper_execution_receipt.completion_contract_result
  =
  if actual_keeper_tool_names = []
  then Contract_violated
  else fallback ()
;;
