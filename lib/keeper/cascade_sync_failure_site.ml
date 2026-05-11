type t =
  | Resume_sync
  | Pause_sync
  | Ambiguous_partial_pause

let to_label = function
  | Resume_sync -> "resume_sync"
  | Pause_sync -> "pause_sync"
  | Ambiguous_partial_pause -> "ambiguous_partial_pause"
;;
