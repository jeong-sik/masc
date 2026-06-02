type t =
  | Ensure_dir_cancelled
  | Ensure_dir_failed
  | Save_atomic_failed
  | Save_atomic_raised

let to_label = function
  | Ensure_dir_cancelled -> "ensure_dir_cancelled"
  | Ensure_dir_failed -> "ensure_dir_failed"
  | Save_atomic_failed -> "save_atomic_failed"
  | Save_atomic_raised -> "save_atomic_raised"
;;
