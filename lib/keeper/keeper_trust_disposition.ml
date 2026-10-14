type t =
  | Pass
  | Alert
  | Blocked
  | Degraded

let to_wire = function
  | Pass -> "Pass"
  | Alert -> "Alert"
  | Blocked -> "Blocked"
  | Degraded -> "Degraded"
;;

let requires_attention = function
  | Pass -> false
  | Alert | Blocked | Degraded -> true
;;
