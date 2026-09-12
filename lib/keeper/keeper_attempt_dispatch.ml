type t = Runtime_attempt_dispatch.t =
  | Dispatched
  | Rejected_before_dispatch

let to_string = Runtime_attempt_dispatch.to_string
