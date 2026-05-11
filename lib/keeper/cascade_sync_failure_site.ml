type t =
  | Resume_sync
  | Pause_sync

let to_label = function
  | Resume_sync -> "resume_sync"
  | Pause_sync -> "pause_sync"
;;
