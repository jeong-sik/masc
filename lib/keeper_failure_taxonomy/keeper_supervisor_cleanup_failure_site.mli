(** Keeper_supervisor_cleanup_failure_site — closed sum for [site] label on
    [metric_keeper_supervisor_cleanup_failures]. *)

type t =
  | Fiber_start_rejected
  | Reconcile_gate_rejected
  | Dead_tombstone_submission
  | Force_watchdog_crash
  | Paused_meta_prune

val to_label : t -> string
