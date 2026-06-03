type actionable_signal =
  | Has_unclaimed_tasks
  | Has_board_activity
  | No_actionable_signal

let actionable_signal_label = function
  | Has_unclaimed_tasks -> "has_unclaimed_tasks"
  | Has_board_activity -> "has_board_activity"
  | No_actionable_signal -> "no_actionable_signal"

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
