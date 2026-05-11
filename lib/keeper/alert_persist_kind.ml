type t =
  | Alert
  | Failed_channels
  | Deadletter

let to_label = function
  | Alert -> "alert"
  | Failed_channels -> "failed_channels"
  | Deadletter -> "deadletter"
;;
