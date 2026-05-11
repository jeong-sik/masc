type t =
  | Turn_failure
  | Keeper_cycle

let to_label = function
  | Turn_failure -> "turn_failure"
  | Keeper_cycle -> "keeper_cycle"
;;
