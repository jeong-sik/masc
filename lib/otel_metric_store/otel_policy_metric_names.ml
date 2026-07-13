(** Policy, board, FSM guard, and memory pipeline metric-name constants.

    Included by {!Otel_metric_store} so existing callers keep using
    [Otel_metric_store.metric_*] bindings unchanged. *)

let metric_anti_rationalization_outcome =
  Otel_metric_store_core.declare_counter "masc_anti_rationalization_outcome_total"

let metric_board_dispatch_flusher_start_outcomes =
  Otel_metric_store_core.declare_counter "masc_board_dispatch_flusher_start_outcomes_total"
;;

let metric_fsm_guard_violation = Otel_metric_store_core.declare_counter "masc_fsm_guard_violation_total"
