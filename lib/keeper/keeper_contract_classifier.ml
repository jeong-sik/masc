type actionable_signal =
  | Has_unclaimed_tasks
  | Has_completion_authority_rejection
  | Has_task_cancellation
  | Has_board_activity
  | No_actionable_signal

let actionable_signal_label = function
  | Has_unclaimed_tasks -> "has_unclaimed_tasks"
  | Has_completion_authority_rejection -> "has_completion_authority_rejection"
  | Has_task_cancellation -> "has_task_cancellation"
  | Has_board_activity -> "has_board_activity"
  | No_actionable_signal -> "no_actionable_signal"

type world_observation = {
  unclaimed_task_count : int;
  board_activity_count : int;
  completion_authority_rejection_count : int;
  (* Cancellations are excluded from [is_board_activity_event] on purpose:
     no Board post backs them. Without their own count a turn driven only by
     a cancellation reports "no_actionable_signal", so the receipt denies the
     very signal that scheduled it. *)
  task_cancellation_count : int;
}

let of_keeper_world_observation
      (observation : Keeper_world_observation.world_observation)
  : world_observation
  =
  {
    unclaimed_task_count = Keeper_world_observation.claimable_task_count observation;
    board_activity_count =
      List.fold_left
        (fun count event ->
           if Keeper_world_observation.is_board_activity_event event
           then count + 1
           else count)
        0
        observation.pending_board_events;
    completion_authority_rejection_count =
      List.fold_left
        (fun count event ->
           if
             Keeper_world_observation.is_completion_authority_rejection_event
               event
           then count + 1
           else count)
        0
        observation.pending_board_events;
    task_cancellation_count =
      List.fold_left
        (fun count event ->
           if Keeper_world_observation.is_task_cancellation_event event
           then count + 1
           else count)
        0
        observation.pending_board_events;
  }

let classify_actionable_signal o =
  if o.unclaimed_task_count > 0 then Has_unclaimed_tasks
  else if o.completion_authority_rejection_count > 0
  then Has_completion_authority_rejection
  else if o.task_cancellation_count > 0 then Has_task_cancellation
  else if o.board_activity_count > 0 then Has_board_activity
  else No_actionable_signal
