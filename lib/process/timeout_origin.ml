type t =
  | Spawn
  | Command

let to_label = function
  | Spawn -> "spawn"
  | Command -> "command"
;;
