type t = Context_overflow | Input_capacity | Request_body_refused

let to_string = function
  | Context_overflow -> "context_overflow"
  | Input_capacity -> "input_capacity"
  | Request_body_refused -> "request_body_refused"
;;

let union left right = List.sort_uniq compare (left @ right)
