type t =
  | Success
  | Checkpoint
  | Input_required
  | Failed
[@@deriving enumerate]

let to_string = function
  | Success -> "success"
  | Checkpoint -> "checkpoint"
  | Input_required -> "input_required"
  | Failed -> "error"
;;

let of_string s = List.find_opt (fun v -> String.equal (to_string v) s) all
;;
