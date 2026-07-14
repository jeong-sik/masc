type t =
  | Retention_prune

let to_label = function
  | Retention_prune -> "retention_prune"
;;
