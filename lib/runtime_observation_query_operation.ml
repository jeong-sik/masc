type t =
  | Read_backlog_snapshot
  | Read_current_task
  | Read_held_task_skills
  | Count_running_keeper_fibers
  | Cursor_stale
  | Board_events
  | Board_stimulus_intake
  | Scheduled_automation
  | Empty_run_reasons
  | Reconcile_read_meta

let to_label = function
  | Read_backlog_snapshot -> "read_backlog_snapshot"
  | Read_current_task -> "read_current_task"
  | Read_held_task_skills -> "read_held_task_skills"
  | Count_running_keeper_fibers -> "count_running_keeper_fibers"
  | Cursor_stale -> "cursor_stale"
  | Board_events -> "board_events"
  | Board_stimulus_intake -> "board_stimulus_intake"
  | Scheduled_automation -> "scheduled_automation"
  | Empty_run_reasons -> "empty_run_reasons"
  | Reconcile_read_meta -> "reconcile_read_meta"
;;
