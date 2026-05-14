(** Supervisor_cleanup_failure_site — closed sum for [site] label on
    [metric_keeper_supervisor_cleanup_failures] (7 sites in
    keeper_supervisor.ml). *)

type t =
  | Fiber_start_rejected
  | Reconcile_gate_rejected
  | Dead_tombstone_meta_write
  | Dead_tombstone_meta_missing
  | Dead_tombstone_meta_error
  | Force_watchdog_crash
  | Paused_meta_prune

val to_label : t -> string
