type t =
  | Progress_snapshot
  | Checkpoint_state_block
  | Checkpoint_structured
  | Meta_fallback_no_snapshot
  | Meta_fallback_no_ctx
  | Meta_fallback_exception

let to_label = function
  | Progress_snapshot -> "progress_snapshot"
  | Checkpoint_state_block -> "checkpoint_state_block"
  | Checkpoint_structured -> "checkpoint_structured"
  | Meta_fallback_no_snapshot -> "meta_fallback_no_snapshot"
  | Meta_fallback_no_ctx -> "meta_fallback_no_ctx"
  | Meta_fallback_exception -> "meta_fallback_exception"
;;
