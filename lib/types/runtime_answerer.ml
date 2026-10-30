type t =
  | Executed of string
  | Not_observed

let to_label = function
  | Executed runtime_id -> runtime_id
  | Not_observed -> "unobserved"
;;
