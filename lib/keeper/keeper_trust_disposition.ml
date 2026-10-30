type t =
  | Pass
  | Alert
  | Blocked
  | Degraded
[@@deriving enumerate]

let to_wire = function
  | Pass -> "Pass"
  | Alert -> "Alert"
  | Blocked -> "Blocked"
  | Degraded -> "Degraded"
;;

let of_wire wire =
  List.find_opt (fun disposition -> String.equal (to_wire disposition) wire) all
;;

let requires_attention = function
  | Pass -> false
  | Alert | Blocked | Degraded -> true
;;
