type t =
  | Read_backlog_counts
  | Count_running_keeper_fibers
  | Cursor_stale
  | Board_events
  | Empty_run_reasons
  | Reconcile_read_meta

let to_label = function
  | Read_backlog_counts -> "read_backlog_counts"
  | Count_running_keeper_fibers -> "count_running_keeper_fibers"
  | Cursor_stale -> "cursor_stale"
  | Board_events -> "board_events"
  | Empty_run_reasons -> "empty_run_reasons"
  | Reconcile_read_meta -> "reconcile_read_meta"
;;
