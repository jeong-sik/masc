type t =
  | Per_request
  | Turn_total
  | Conversation_cumulative
  | Usage_scope_unavailable
[@@deriving enumerate]

let to_string = function
  | Per_request -> "per_request"
  | Turn_total -> "turn_total"
  | Conversation_cumulative -> "conversation_cumulative"
  | Usage_scope_unavailable -> "unavailable"
;;

let of_string s = List.find_opt (fun v -> String.equal (to_string v) s) all
;;
