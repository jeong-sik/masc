type actionable_signal =
  | Has_unclaimed_tasks
  | Has_board_activity
  | No_actionable_signal

type actionable_signal_context =
  | No_actionable_signal_context
  | Turn_affordance_requires_tool
  | Keeper_world_signal of actionable_signal

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
  | No_actionable_signal -> "no_actionable_signal"

let actionable_signal_context_label = function
  | No_actionable_signal_context -> "no_actionable_signal_context"
  | Turn_affordance_requires_tool -> "turn_affordance_requires_tool"
  | Keeper_world_signal signal -> actionable_signal_label signal

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
}

let of_keeper_world_observation
      (observation : Keeper_world_observation.world_observation)
  : world_observation
  =
  {
    unclaimed_task_count = observation.claimable_task_count;
    board_activity_count = List.length observation.pending_board_events;
  }

let classify_actionable_signal o =
  if o.unclaimed_task_count > 0 then Has_unclaimed_tasks
  else if o.board_activity_count > 0 then Has_board_activity
  else No_actionable_signal

let classify_actionable_signal_for_tools ~(allowed_tool_names : string list) o =
  let has_tool capability =
    Keeper_tool_capability_axis.supports_any capability allowed_tool_names
  in
  if
    o.unclaimed_task_count > 0
    && has_tool Keeper_tool_capability_axis.Claim_task
  then Has_unclaimed_tasks
  else if
    o.board_activity_count > 0
    && has_tool Keeper_tool_capability_axis.Board_activity
  then Has_board_activity
  else No_actionable_signal

let make_actionable_signal_context ~tool_gate_required ~actionable_signal =
  if tool_gate_required
  then Turn_affordance_requires_tool
  else
    match actionable_signal with
    | No_actionable_signal -> No_actionable_signal_context
    | signal -> Keeper_world_signal signal

let is_actionable = function
  | No_actionable_signal -> false
  | Has_unclaimed_tasks | Has_board_activity -> true

let is_actionable_signal_context = function
  | No_actionable_signal_context -> false
  | Turn_affordance_requires_tool | Keeper_world_signal _ -> true

let requires_tool_support_for_allowed_tools ~(allowed_tool_names : string list) o =
  o
  |> classify_actionable_signal_for_tools ~allowed_tool_names
  |> is_actionable
