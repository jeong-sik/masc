type t =
  | Ok
  | No_checkpoint
  | Precondition
  | Not_found

let to_label = function
  | Ok -> "ok"
  | No_checkpoint -> "no_checkpoint"
  | Precondition -> "precondition"
  | Not_found -> "not_found"
;;
