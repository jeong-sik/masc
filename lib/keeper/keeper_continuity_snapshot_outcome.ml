type t =
  | From_state_block
  | From_structured_checkpoint
  | Missing_no_snapshot

let to_label = function
  | From_state_block -> "from_state_block"
  | From_structured_checkpoint -> "from_structured_checkpoint"
  | Missing_no_snapshot -> "missing_no_snapshot"
;;
