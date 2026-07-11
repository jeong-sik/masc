type t =
  | Fiber_start_rejected
  | Reconcile_gate_rejected
  | Dead_tombstone_submission
  | Force_watchdog_crash
  | Paused_meta_prune

let to_label = function
  | Fiber_start_rejected -> "fiber_start_rejected"
  | Reconcile_gate_rejected -> "reconcile_gate_rejected"
  | Dead_tombstone_submission -> "dead_tombstone_submission"
  | Force_watchdog_crash -> "force_watchdog_crash"
  | Paused_meta_prune -> "paused_meta_prune"
;;
