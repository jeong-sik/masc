type t =
  | Cancelled
  | Exception

let to_label = function
  | Cancelled -> "cancelled"
  | Exception -> "exception"
;;
