(** Policy, board, FSM guard, and memory pipeline metric-name constants.

    Included by {!Otel_metric_store} so existing callers keep using
    [Otel_metric_store.metric_*] bindings unchanged. *)

(** Aggregate counter for every fallback event across the runtime pipeline.
    Labels: [kind] enumerates the fallback class and [detail] carries the
    specific reason within the kind. *)

(** Counter for board flusher actor startup non-success outcomes.
    Closed-vocabulary label [outcome] is [switch_finished | cas_exhausted]. *)
val metric_board_dispatch_flusher_start_outcomes : string

val metric_anti_rationalization_outcome : string

(** Runtime FSM guard assertion violations observed by
    [Keeper_fsm_guard_runtime.wrap_unit]. Labels: [action, stage]. A non-zero
    value means runtime behavior drifted from the TLA-backed contract surface. *)
val metric_fsm_guard_violation : string

(** Wall-clock seconds spent in the memory pipeline flush bridge. *)
