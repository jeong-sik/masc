(** Policy, board, FSM guard, and memory pipeline metric-name constants.

    Included by {!Prometheus} so existing callers keep using
    [Prometheus.metric_*] bindings unchanged. *)

let metric_anti_rationalization_fallback = "masc_anti_rationalization_fallback_total"

let metric_anti_rationalization_excuse_pattern =
  "masc_anti_rationalization_excuse_pattern_total"
;;

let metric_board_truncated_posts = "masc_board_truncated_posts_total"

let metric_board_dispatch_flusher_start_outcomes =
  "masc_board_dispatch_flusher_start_outcomes_total"
;;

let metric_fsm_guard_violation = "masc_fsm_guard_violation_total"
let metric_memory_pipeline_flushes = "masc_memory_pipeline_flushes_total"
let metric_memory_pipeline_flush_records = "masc_memory_pipeline_flush_records_total"

let metric_memory_pipeline_flush_duration_seconds =
  "masc_memory_pipeline_flush_duration_seconds"
;;
