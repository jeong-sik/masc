(** Policy, board, FSM guard, and memory pipeline metric-name constants.

    Included by {!Prometheus} so existing callers keep using
    [Prometheus.metric_*] bindings unchanged. *)

(** Aggregate counter for every fallback event across the cascade pipeline.
    Labels: [kind] enumerates the fallback class and [detail] carries the
    specific reason within the kind. *)
val metric_board_truncated_posts : string

(** Counter for board flusher actor startup non-success outcomes.
    Closed-vocabulary label [outcome] is [switch_finished | cas_exhausted]. *)
val metric_board_dispatch_flusher_start_outcomes : string

val metric_anti_rationalization_fallback : string

(** Per-pattern and per-decision counter for the gate 2 excuse substring
    detector. Decision label is
    [advisory_to_llm | terminal_reject | advisory_safety_net_reject]. *)
val metric_anti_rationalization_excuse_pattern : string

(** Runtime FSM guard assertion violations observed by
    [Keeper_fsm_guard_runtime.wrap_unit]. Labels: [action, stage]. A non-zero
    value means runtime behavior drifted from the TLA-backed contract surface. *)
val metric_fsm_guard_violation : string

val metric_memory_pipeline_flushes : string
val metric_memory_pipeline_flush_records : string

(** Wall-clock seconds spent in the memory pipeline flush bridge. *)
val metric_memory_pipeline_flush_duration_seconds : string
