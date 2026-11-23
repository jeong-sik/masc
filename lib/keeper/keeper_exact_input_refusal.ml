type t = Context_overflow | Input_capacity | Request_body_refused [@@deriving enumerate]

let to_string = function
  | Context_overflow -> "context_overflow"
  | Input_capacity -> "input_capacity"
  | Request_body_refused -> "request_body_refused"
;;

let rank = function
  | Context_overflow -> 0
  | Input_capacity -> 1
  | Request_body_refused -> 2
;;

let compare a b = Int.compare (rank a) (rank b)

let union left right = List.sort_uniq compare (left @ right)

let of_string s = List.find_opt (fun v -> String.equal (to_string v) s) all
