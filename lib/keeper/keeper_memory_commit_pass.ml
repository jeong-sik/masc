type t =
  | Admission
  | Durable
  | Continuity
  | Cleanup
  | Program_publish
  | Keeper_write
  | Keeper_delete
  | Operator_delete

let to_label = function
  | Admission -> "admission"
  | Durable -> "durable"
  | Continuity -> "continuity"
  | Cleanup -> "cleanup"
  | Program_publish -> "program_publish"
  | Keeper_write -> "keeper_write"
  | Keeper_delete -> "keeper_delete"
  | Operator_delete -> "operator_delete"
;;
