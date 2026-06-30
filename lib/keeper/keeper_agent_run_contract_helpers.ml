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

let observed_completion_contract_status
      ~had_owned_active_task_at_turn_start ~actual_keeper_tool_names
      ~response_text_present
  : Keeper_execution_receipt.completion_contract_result
  =
  if (not response_text_present) && actual_keeper_tool_names = []
  then Contract_violated
  else
    Keeper_agent_run_turn_helpers.completion_contract_result_for_progress_evidence
      ~had_owned_active_task_at_turn_start
      ~actual_keeper_tool_names
;;

let text_only_violation_contract_status ~actual_keeper_tool_names ~fallback
  : Keeper_execution_receipt.completion_contract_result
  =
  if actual_keeper_tool_names = []
  then Contract_violated
  else fallback ()
;;
