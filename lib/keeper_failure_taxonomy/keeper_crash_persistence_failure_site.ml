type t =
  | Crash_write

let to_label = function
  | Crash_write -> "crash_write"
;;
