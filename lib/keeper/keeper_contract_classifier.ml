type actionable_signal =
  | Has_unclaimed_tasks
  | Has_board_activity
  | No_actionable_signal

type contract_status =
  | Surface_mismatch of { missing : string list }
  | Claim_only_after_owned_task
  | Needs_execution_progress
  | Passive_only
  | Satisfied_completion
  | Satisfied_execution

let actionable_signal_label = function
  | Has_unclaimed_tasks -> "has_unclaimed_tasks"
  | Has_board_activity -> "has_board_activity"
  | No_actionable_signal -> "no_actionable_signal"

let contract_status_label = function
  | Surface_mismatch _ -> "surface_mismatch"
  | Claim_only_after_owned_task -> "claim_only_after_owned_task"
  | Needs_execution_progress -> "needs_execution_progress"
  | Passive_only -> "passive_only"
  | Satisfied_completion -> "satisfied_completion"
  | Satisfied_execution -> "satisfied_execution"

let pp_contract_status fmt = function
  | Surface_mismatch { missing } ->
      Format.fprintf fmt "surface_mismatch(missing=[%s])"
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

let is_actionable = function
  | No_actionable_signal -> false
  | Has_unclaimed_tasks | Has_board_activity -> true
