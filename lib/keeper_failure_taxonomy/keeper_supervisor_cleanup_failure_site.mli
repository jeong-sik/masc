(** Keeper_supervisor_cleanup_failure_site — closed sum for [site] label on
    [metric_keeper_supervisor_cleanup_failures]. *)

type t =
  | Fiber_start_rejected
  | Dead_tombstone_submission
  | Paused_meta_read
  | Paused_meta_prune_submission

val to_label : t -> string
