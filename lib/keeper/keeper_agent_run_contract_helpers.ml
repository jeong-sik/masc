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
