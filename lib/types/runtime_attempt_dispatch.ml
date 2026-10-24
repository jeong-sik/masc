type t =
  | Dispatched
  | Rejected_before_dispatch

let to_string = function
  | Dispatched -> "dispatched"
  | Rejected_before_dispatch -> "rejected_before_dispatch"
;;

type continuation = Next_may_dispatch | Original_must_resolve
