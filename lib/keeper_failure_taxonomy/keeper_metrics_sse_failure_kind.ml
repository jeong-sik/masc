type t =
  | Compaction

let to_label = function
  | Compaction -> "compaction"
;;
