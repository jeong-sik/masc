type t =
  | Session_cooldown
  | Window_limit

let to_label = function
  | Session_cooldown -> "session_cooldown"
  | Window_limit -> "window_limit"
;;
