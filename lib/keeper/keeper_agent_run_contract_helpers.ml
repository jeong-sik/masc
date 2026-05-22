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

let keeper_tool_names_for_outcome
      ~(allowed_tool_names : string list)
      ~(tool_calls : Keeper_agent_result.tool_call_detail list)
      ~(outcome : string)
  : string list
  =
  let observed_tool_names =
    tool_calls
    |> List.rev
    |> List.filter_map (fun (detail : Keeper_agent_result.tool_call_detail) ->
      if String.equal detail.outcome outcome then Some detail.tool_name else None)
  in
  Keeper_tool_disclosure.final_keeper_tool_names
    ~reported_tool_names:[]
    ~observed_tool_names
    ~allowed_tool_names
;;

let progress_keeper_tool_names_for_contract
      ~(allowed_tool_names : string list)
      ~(actual_keeper_tool_names : string list)
      ~(tool_calls : Keeper_agent_result.tool_call_detail list)
  : string list
  =
  match tool_calls with
  | [] -> actual_keeper_tool_names
  | _ :: _ -> keeper_tool_names_for_outcome ~allowed_tool_names ~tool_calls ~outcome:"ok"
;;

let no_progress_success_tool_names_for_contract
      ~(allowed_tool_names : string list)
      ~(tool_calls : Keeper_agent_result.tool_call_detail list)
  : string list
  =
  keeper_tool_names_for_outcome ~allowed_tool_names ~tool_calls ~outcome:"ok_no_progress"
;;

let completion_contract_violation_error reason =
  Agent_sdk.Error.Agent
    (Agent_sdk.Error.CompletionContractViolation
       { contract = Agent_sdk.Completion_contract_id.Require_tool_use
       ; reason
       ; violation_detail = None
       })
;;

let observed_tool_contract_status ~required_tool_names ~missing_visible_required
      ~had_owned_active_task_at_turn_start ~actual_keeper_tool_names
  : Keeper_execution_receipt.tool_contract_result
  =
  Keeper_agent_tool_surface.tool_contract_result_for_observed_tools
    ~required_tool_names ~missing_visible_required ~had_owned_active_task_at_turn_start
    ~actual_keeper_tool_names
;;

let passive_violation_contract_status ~actual_keeper_tool_names
      ~progress_keeper_tool_names ~fallback
  : Keeper_execution_receipt.tool_contract_result
  =
  if actual_keeper_tool_names = []
  then Contract_missing_required_tool_use
  else if progress_keeper_tool_names = []
  then Contract_needs_execution_progress
  else fallback ()
;;

let text_only_violation_contract_status ~actual_keeper_tool_names ~fallback
  : Keeper_execution_receipt.tool_contract_result
  =
  if actual_keeper_tool_names = []
  then Contract_missing_required_tool_use
  else fallback ()
;;
