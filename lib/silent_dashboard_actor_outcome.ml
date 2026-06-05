type t =
  | None_resolved
  | Error_classified

let to_label = function
  | None_resolved -> "none"
  | Error_classified -> "error"
;;
