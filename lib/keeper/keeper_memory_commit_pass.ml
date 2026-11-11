type t =
  | Admission
  | Durable
  | Continuity
  | Cleanup
  | Keeper_write
  | Keeper_delete
  | Operator_delete
[@@deriving enumerate]

let to_label = function
  | Admission -> "admission"
  | Durable -> "durable"
  | Continuity -> "continuity"
  | Cleanup -> "cleanup"
  | Keeper_write -> "keeper_write"
  | Keeper_delete -> "keeper_delete"
  | Operator_delete -> "operator_delete"
;;
