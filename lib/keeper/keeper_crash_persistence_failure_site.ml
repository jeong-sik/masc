type t =
  | Crash_write
  | Sp_write

let to_label = function
  | Crash_write -> "crash_write"
  | Sp_write -> "sp_write"
;;
