type t =
  | Compaction
  | Handoff

let to_label = function
  | Compaction -> "compaction"
  | Handoff -> "handoff"
;;
