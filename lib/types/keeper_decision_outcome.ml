type t =
  | Success
  | Checkpoint
  | Input_required
  | Failed

let to_string = function
  | Success -> "success"
  | Checkpoint -> "checkpoint"
  | Input_required -> "input_required"
  | Failed -> "error"
;;

let of_string = function
  | "success" -> Some Success
  | "checkpoint" -> Some Checkpoint
  | "input_required" -> Some Input_required
  | "error" -> Some Failed
  | _ -> None
;;
