type t =
  | Success
  | Checkpoint
  | Input_required
  | Error

let to_string = function
  | Success -> "success"
  | Checkpoint -> "checkpoint"
  | Input_required -> "input_required"
  | Error -> "error"
;;

let of_string = function
  | "success" -> Some Success
  | "checkpoint" -> Some Checkpoint
  | "input_required" -> Some Input_required
  | "error" -> Some Error
  | _ -> None
;;
