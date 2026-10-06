type t =
  | Priority
  | Standard

let to_string = function
  | Priority -> "priority"
  | Standard -> "standard"
;;
