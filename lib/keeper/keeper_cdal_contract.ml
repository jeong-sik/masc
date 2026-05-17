module RC = Masc_mcp_cdal_runtime.Risk_contract
module EM = Masc_mcp_cdal_runtime.Execution_mode
module RK = Masc_mcp_cdal_runtime.Risk_class

let string_list_to_json values =
  `List (List.map (fun value -> `String value) values)
;;

let string_opt_to_json = function
  | None -> `Null
  | Some value -> `String value
;;

let task_id_opt_to_json = function
  | None -> `Null
  | Some task_id -> `String (Keeper_id.Task_id.to_string task_id)
;;

let of_keeper_meta (meta : Keeper_types.keeper_meta) : RC.t option =
  let runtime_constraints : RC.runtime_constraints =
    { requested_execution_mode = EM.Execute
    ; risk_class = RK.Low
    ; allowed_mutations = []
    ; review_requirement = None
    }
  in
  let eval_criteria =
    `Assoc
      [ "kind", `String "keeper_turn_capture_v1"
      ; "keeper_name", `String meta.name
      ; "agent_name", `String meta.agent_name
      ; "sandbox_profile", `String (Keeper_types.sandbox_profile_to_string meta.sandbox_profile)
      ; "network_mode", `String (Keeper_types.network_mode_to_string meta.network_mode)
      ; "sandbox_image", string_opt_to_json meta.sandbox_image
      ; "tool_access", Keeper_types.tool_access_to_json meta.tool_access
      ; "tool_denylist", string_list_to_json meta.tool_denylist
      ; "allowed_paths", string_list_to_json meta.allowed_paths
      ; "active_goal_ids", string_list_to_json meta.active_goal_ids
      ; "current_task_id_at_start", task_id_opt_to_json meta.current_task_id
      ]
  in
  Some { RC.runtime_constraints; eval_criteria }
;;
