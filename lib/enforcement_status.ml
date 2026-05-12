type t =
  | Conditional
  | Enforced
  | Advisory_only

let to_label = function
  | Conditional -> "conditional"
  | Enforced -> "enforced"
  | Advisory_only -> "advisory_only"
;;
