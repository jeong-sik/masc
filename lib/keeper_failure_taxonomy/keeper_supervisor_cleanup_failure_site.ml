type t =
  | Fiber_start_rejected
  | Dead_tombstone_submission
  | Paused_meta_read
  | Paused_meta_prune_submission

let to_label = function
  | Fiber_start_rejected -> "fiber_start_rejected"
  | Dead_tombstone_submission -> "dead_tombstone_submission"
  | Paused_meta_read -> "paused_meta_read"
  | Paused_meta_prune_submission -> "paused_meta_prune_submission"
;;
