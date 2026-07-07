type t =
  | Read_backlog_counts
  | Read_current_task
  | Count_running_keeper_fibers
  | Cursor_stale
  | Board_events
  | Scheduled_automation
  | Empty_run_reasons
  | Reconcile_read_meta

let to_label = function
  | Read_backlog_counts -> "read_backlog_counts"
  | Read_current_task -> "read_current_task"
  | Count_running_keeper_fibers -> "count_running_keeper_fibers"
  | Cursor_stale -> "cursor_stale"
  | Board_events -> "board_events"
  | Scheduled_automation -> "scheduled_automation"
  | Empty_run_reasons -> "empty_run_reasons"
  | Reconcile_read_meta -> "reconcile_read_meta"
;;
