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
