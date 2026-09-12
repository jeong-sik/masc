type t =
  | Dispatched
  | Rejected_before_dispatch

let to_string = function
  | Dispatched -> "dispatched"
  | Rejected_before_dispatch -> "rejected_before_dispatch"
;;
