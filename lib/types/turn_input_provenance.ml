type t =
  | Measured_request
  | Context_estimate
[@@deriving enumerate]

let to_string = function
  | Measured_request -> "measured_request"
  | Context_estimate -> "context_estimate"
;;

let of_string s = List.find_opt (fun v -> String.equal (to_string v) s) all
;;
