type actionable_signal =
  | Has_unclaimed_tasks
  | Has_board_activity
  | Has_discovered_work
  | No_actionable_signal

type contract_status =
  | Tool_surface_mismatch of { missing : string list }
  | Missing_required_tool_use
  | Claim_only_after_owned_task
  | Needs_execution_progress
  | Passive_only
  | Satisfied_completion
  | Satisfied_execution

let actionable_signal_label = function
  | Has_unclaimed_tasks -> "has_unclaimed_tasks"
  | Has_board_activity -> "has_board_activity"
  | Has_discovered_work -> "has_discovered_work"
  | No_actionable_signal -> "no_actionable_signal"

let contract_status_label = function
  | Tool_surface_mismatch _ -> "tool_surface_mismatch"
  | Missing_required_tool_use -> "missing_required_tool_use"
  | Claim_only_after_owned_task -> "claim_only_after_owned_task"
  | Needs_execution_progress -> "needs_execution_progress"
  | Passive_only -> "passive_only"
  | Satisfied_completion -> "satisfied_completion"
  | Satisfied_execution -> "satisfied_execution"

let pp_contract_status fmt = function
  | Tool_surface_mismatch { missing } ->
      Format.fprintf fmt "tool_surface_mismatch(missing=[%s])"
        (String.concat ", " missing)
  | other -> Format.pp_print_string fmt (contract_status_label other)

type world_observation = {
  unclaimed_task_count : int;
  board_activity_count : int;
  has_discovered_work_section : bool;
}

let of_keeper_world_observation
      (observation : Keeper_world_observation.world_observation)
  : world_observation
  =
  {
    unclaimed_task_count = observation.claimable_task_count;
    board_activity_count = List.length observation.pending_board_events;
    has_discovered_work_section =
      observation.work_discovery_due
      || Option.is_some observation.worktree_change_summary;
  }

let classify_actionable_signal o =
  if o.unclaimed_task_count > 0 then Has_unclaimed_tasks
  else if o.board_activity_count > 0 then Has_board_activity
  else if o.has_discovered_work_section then Has_discovered_work
  else No_actionable_signal

let classify_actionable_signal_for_tools ~(allowed_tool_names : string list) o =
  let has_any_tool names =
    List.exists (fun name -> List.mem name allowed_tool_names) names
  in
  if
    o.unclaimed_task_count > 0
    && has_any_tool [ "keeper_task_claim"; "masc_claim_next"; "masc_claim_task" ]
  then Has_unclaimed_tasks
  else if
    o.board_activity_count > 0
    && has_any_tool
         [ "keeper_board_post"; "keeper_board_comment"; "masc_broadcast";
           "masc_keeper_msg" ]
  then Has_board_activity
  else if
    o.has_discovered_work_section
    && has_any_tool
         [ "keeper_board_post"; "masc_add_task"; "keeper_tasks_audit";
           "keeper_shell"; "keeper_bash"; "masc_code_git"; "keeper_fs_read" ]
  then Has_discovered_work
  else No_actionable_signal

let classify_actionable_signal_with_allowed_tools =
  classify_actionable_signal_for_tools

let is_actionable = function
  | No_actionable_signal -> false
  | Has_unclaimed_tasks | Has_board_activity | Has_discovered_work -> true
