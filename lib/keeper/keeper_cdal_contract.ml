module RC = Masc_mcp_cdal_runtime.Risk_contract
module Crit = Masc_mcp_cdal_runtime.Criteria
module EM = Masc_mcp_cdal_runtime.Execution_mode
module RK = Masc_mcp_cdal_runtime.Risk_class


let of_keeper_meta (meta : Keeper_types.keeper_meta) : RC.t option =
  let runtime_constraints : RC.runtime_constraints =
    { requested_execution_mode = EM.Execute
    ; risk_class = RK.Low
    ; allowed_mutations = []
    ; review_requirement = None
    }
  in
  let current_task_id =
    Option.map Keeper_id.Task_id.to_string meta.current_task_id
  in
  let eval_criteria : Crit.t =
    Crit.Keeper_turn_capture_v1
      { keeper_name = meta.name
      ; agent_name = meta.agent_name
      ; sandbox_profile = Keeper_types.sandbox_profile_to_string meta.sandbox_profile
      ; sandbox_image = meta.sandbox_image
      ; network_mode = Keeper_types.network_mode_to_string meta.network_mode
      ; tool_access = Keeper_types.tool_access_to_json meta.tool_access
      ; tool_denylist = meta.tool_denylist
      ; allowed_paths = meta.allowed_paths
      ; active_goal_ids = meta.active_goal_ids
      ; current_task_id
      }
  in
  Some { RC.runtime_constraints; eval_criteria }
;;
