type t =
  | Priority
  | Standard
  | Background

let to_string = function
  | Priority -> "priority"
  | Standard -> "standard"
  | Background -> "background"
;;
