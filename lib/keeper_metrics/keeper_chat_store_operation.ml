type t =
  | Append
  | Load

let to_label = function
  | Append -> "append"
  | Load -> "load"
;;
